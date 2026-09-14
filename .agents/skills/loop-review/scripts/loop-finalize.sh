#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR="${LOOP_DIR:-.skills-workspace/loop}"
STATE_DIR="$LOOP_DIR/.state"
HASH_SCRIPT="$(dirname "$0")/loop-hash.sh"

dest="${1:-}"
if [[ -z "$dest" && -f "$LOOP_DIR/source.path" ]]; then
  dest="$(cat "$LOOP_DIR/source.path")"
fi
if [[ -z "$dest" ]]; then
  echo "loop-finalize: no destination path; pass DEST_PATH or run from a cycle that recorded source.path" >&2
  exit 1
fi

if [[ ! -f "$LOOP_DIR/.approved" ]]; then
  echo "loop-finalize: cycle not approved ($LOOP_DIR/.approved missing)" >&2
  exit 1
fi

if [[ ! -f "$LOOP_DIR/plan.md" ]]; then
  echo "loop-finalize: no plan to merge ($LOOP_DIR/plan.md missing)" >&2
  exit 1
fi

if [[ ! -f "$STATE_DIR/review_seen_plan_hash" ]]; then
  echo "loop-finalize: missing $STATE_DIR/review_seen_plan_hash; cannot verify approval hash" >&2
  exit 1
fi
plan_hash="$("$HASH_SCRIPT" "$LOOP_DIR/plan.md")"
approved_hash=""
if [[ -f "$STATE_DIR/review_seen_plan_hash" ]]; then
  IFS= read -r approved_hash < "$STATE_DIR/review_seen_plan_hash" || true
fi
if [[ "$plan_hash" != "$approved_hash" ]]; then
  echo "loop-finalize: plan.md changed after approval; reset and re-cycle" >&2
  exit 1
fi

dest_dir="$(dirname "$dest")"
if [[ ! -d "$dest_dir" ]]; then
  echo "loop-finalize: destination dir missing: $dest_dir" >&2
  exit 1
fi

if [[ -e "$dest" ]]; then
  dest_path="$(realpath "$dest")"
else
  dest_path="$(cd "$dest_dir" && pwd -P)/$(basename "$dest")"
fi
plan_path="$(realpath "$LOOP_DIR/plan.md")"

if [[ "$dest_path" == "$plan_path" ]]; then
  echo "loop-finalize: dest equals sandbox plan; nothing to do" >&2
  exit 1
fi

tmp="$dest.tmp.$$"
cp "$LOOP_DIR/plan.md" "$tmp"
mv "$tmp" "$dest"

rm -rf \
  "$LOOP_DIR/plan.md" \
  "$LOOP_DIR/review.md" \
  "$LOOP_DIR/task.md" \
  "$LOOP_DIR/source.path" \
  "$LOOP_DIR/.approved" \
  "$STATE_DIR"
mkdir -p "$STATE_DIR"

echo "loop-finalize: merged plan to $dest; sandbox cleaned"
