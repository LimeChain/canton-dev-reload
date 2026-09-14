#!/usr/bin/env bash
set -euo pipefail

role="${1:?usage: loop-next.sh plan|review [--wait SECONDS]}"
shift || true

wait_seconds=0
if [[ "${1:-}" == "--wait" ]]; then
  wait_seconds="${2:-60}"
fi

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
STATE_DIR="$LOOP_DIR/.state"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR"

deadline=$((SECONDS + wait_seconds))

check_once() {
  if [[ -f "$LOOP_DIR/.approved" ]]; then
    echo "APPROVED: loop already approved"
    return 2
  fi

  if [[ -f "$LOOP_DIR/.stalemate" ]]; then
    echo "STALEMATE: cycle stalemated"
    return 3
  fi

  case "$role" in
    plan)
      if [[ ! -f "$LOOP_DIR/plan.md" ]]; then
        echo "TURN: plan first-pass; write $LOOP_DIR/plan.md"
        return 0
      fi

      if [[ ! -f "$STATE_DIR/plan_written_plan_hash" ]]; then
        echo "TURN: plan recommit; plan.md exists but no commit recorded; review $LOOP_DIR/plan.md and run $scripts_dir/loop-done.sh plan"
        return 0
      fi

      if [[ -f "$STATE_DIR/review_written_review_hash" ]]; then
        written_review_hash=""
        IFS= read -r written_review_hash < "$STATE_DIR/review_written_review_hash" || true
        seen_review_hash=""
        if [[ -f "$STATE_DIR/plan_seen_review_hash" ]]; then
          IFS= read -r seen_review_hash < "$STATE_DIR/plan_seen_review_hash" || true
        fi
        if [[ "$written_review_hash" != "$seen_review_hash" ]]; then
          if [[ -f "$LOOP_DIR/review.md" ]] && grep -qE '^STATUS:[[:space:]]*APPROVED[[:space:]]*$' "$LOOP_DIR/review.md"; then
            touch "$LOOP_DIR/.approved"
            echo "APPROVED: review approved"
            return 2
          fi
          echo "TURN: plan revision; review changed; update $LOOP_DIR/plan.md"
          return 0
        fi
      fi

      echo "NO_TURN: plan is waiting for review feedback"
      return 1
      ;;

    review)
      if [[ ! -f "$STATE_DIR/plan_written_plan_hash" ]] || [[ ! -f "$LOOP_DIR/plan.md" ]]; then
        echo "NO_TURN: review is waiting for plan commit ($scripts_dir/loop-done.sh plan)"
        return 1
      fi

      written_plan_hash=""
      IFS= read -r written_plan_hash < "$STATE_DIR/plan_written_plan_hash" || true
      seen_plan_hash=""
      if [[ -f "$STATE_DIR/review_seen_plan_hash" ]]; then
        IFS= read -r seen_plan_hash < "$STATE_DIR/review_seen_plan_hash" || true
      fi
      if [[ "$written_plan_hash" != "$seen_plan_hash" ]]; then
        echo "TURN: review; plan changed; write $LOOP_DIR/review.md"
        return 0
      fi

      echo "NO_TURN: review is waiting for plan changes"
      return 1
      ;;

    *)
      echo "usage: loop-next.sh plan|review [--wait SECONDS]" >&2
      return 64
      ;;
  esac
}

while true; do
  set +e
  output="$(check_once)"
  status=$?
  set -e

  case "$status" in
    0|2|3|64)
      echo "$output"
      exit "$status"
      ;;
  esac

  if (( SECONDS >= deadline )); then
    echo "$output"
    exit 1
  fi

  sleep 2
done
