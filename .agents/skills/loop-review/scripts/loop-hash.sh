#!/usr/bin/env bash
set -euo pipefail

file="${1:?usage: loop-hash.sh FILE}"

if [[ ! -f "$file" ]]; then
  echo "missing"
  exit 0
fi

if command -v sha256sum >/dev/null 2>&1; then
  read -r hash _ < <(sha256sum "$file")
  printf '%s\n' "$hash"
elif command -v shasum >/dev/null 2>&1; then
  read -r hash _ < <(shasum -a 256 "$file")
  printf '%s\n' "$hash"
else
  read -r f1 f2 _ < <(cksum "$file")
  printf '%s:%s\n' "$f1" "$f2"
fi
