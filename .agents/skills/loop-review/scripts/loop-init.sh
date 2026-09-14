#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
STATE_DIR="$LOOP_DIR/.state"

mkdir -p "$STATE_DIR"

if [[ $# -gt 0 && ! -s "$LOOP_DIR/task.md" ]]; then
  printf '%s\n' "$*" > "$LOOP_DIR/task.md"
fi

: > "$STATE_DIR/.keep"

echo "loop initialized at $LOOP_DIR"
if [[ -s "$LOOP_DIR/task.md" ]]; then
  echo "task: $LOOP_DIR/task.md"
else
  echo "task: missing; create $LOOP_DIR/task.md or invoke plan with task text"
fi
