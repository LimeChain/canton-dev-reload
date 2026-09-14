#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
rm -rf "$LOOP_DIR/.state" "$LOOP_DIR/.approved" "$LOOP_DIR/.stalemate"
mkdir -p "$LOOP_DIR/.state"
echo "reset loop state; kept task.md, plan.md, and review.md if present"
