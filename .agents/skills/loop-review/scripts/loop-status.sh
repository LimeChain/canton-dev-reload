#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
STATE_DIR="$LOOP_DIR/.state"
HASH_SCRIPT="$(dirname "$0")/loop-hash.sh"

mkdir -p "$STATE_DIR"

status="in_progress"
if [[ -f "$LOOP_DIR/.approved" ]]; then
  status="approved"
elif [[ -f "$LOOP_DIR/review.md" ]] && grep -qE '^STATUS:[[:space:]]*STALEMATE[[:space:]]*$' "$LOOP_DIR/review.md"; then
  status="stalemate_review"
elif [[ -f "$LOOP_DIR/.stalemate" ]]; then
  status="stalemate_plan"
elif [[ -f "$LOOP_DIR/review.md" ]] && grep -qE '^STATUS:[[:space:]]*APPROVED[[:space:]]*$' "$LOOP_DIR/review.md"; then
  status="approved_review_present"
fi

printf 'status: %s\n' "$status"
printf 'task: %s\n' "$([[ -s "$LOOP_DIR/task.md" ]] && echo present || echo missing)"
printf 'plan: %s\n' "$([[ -s "$LOOP_DIR/plan.md" ]] && echo present || echo missing)"
printf 'review: %s\n' "$([[ -s "$LOOP_DIR/review.md" ]] && head -n 1 "$LOOP_DIR/review.md" || echo missing)"
printf 'plan_hash: %s\n' "$($HASH_SCRIPT "$LOOP_DIR/plan.md")"
printf 'review_hash: %s\n' "$($HASH_SCRIPT "$LOOP_DIR/review.md")"
printf 'review_seen_plan_hash: %s\n' "$(cat "$STATE_DIR/review_seen_plan_hash" 2>/dev/null || echo none)"
printf 'plan_seen_review_hash: %s\n' "$(cat "$STATE_DIR/plan_seen_review_hash" 2>/dev/null || echo none)"
