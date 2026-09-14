#!/usr/bin/env bash
set -euo pipefail

role="${1:?usage: loop-done.sh plan|review}"

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
STATE_DIR="$LOOP_DIR/.state"
HASH_SCRIPT="$(dirname "$0")/loop-hash.sh"

mkdir -p "$STATE_DIR"

case "$role" in
  plan)
    "$HASH_SCRIPT" "$LOOP_DIR/review.md" > "$STATE_DIR/plan_seen_review_hash"
    "$HASH_SCRIPT" "$LOOP_DIR/plan.md" > "$STATE_DIR/plan_written_plan_hash"
    echo "plan done"
    ;;
  review)
    if [[ ! -f "$LOOP_DIR/review.md" ]]; then
      echo "review cannot finish: missing $LOOP_DIR/review.md" >&2
      exit 1
    fi

    if [[ -f "$LOOP_DIR/.approved" ]] || [[ -f "$LOOP_DIR/.stalemate" ]]; then
      echo "review cannot republish: cycle is already terminal (run loop-reset.sh to start over)" >&2
      exit 1
    fi

    "$HASH_SCRIPT" "$LOOP_DIR/plan.md" > "$STATE_DIR/review_seen_plan_hash"
    "$HASH_SCRIPT" "$LOOP_DIR/review.md" > "$STATE_DIR/review_written_review_hash"

    if grep -qE '^STATUS:[[:space:]]*APPROVED[[:space:]]*$' "$LOOP_DIR/review.md"; then
      touch "$LOOP_DIR/.approved"
      echo "review done: approved"
    elif grep -qE '^STATUS:[[:space:]]*STALEMATE[[:space:]]*$' "$LOOP_DIR/review.md"; then
      printf 'review-declared; see %s/review.md ## Notes\n' "$LOOP_DIR" > "$LOOP_DIR/.stalemate"
      echo "review done: stalemate"
    else
      echo "review done: issues"
    fi
    ;;
  *)
    echo "usage: loop-done.sh plan|review" >&2
    exit 64
    ;;
esac
