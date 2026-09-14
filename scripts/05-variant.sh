#!/usr/bin/env bash
# Switch the model to a variant and rebuild. daml.yaml name+version are NEVER touched --
# holding name/version constant while the package ID moves is the whole point.
# Rebuilds the seed package too, so the script always matches the model it seeds.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh
v="${1:-}"
# `live` builds whatever the developer has actually typed into the source file, instead of
# copying a canned variant over it. That is what the demo uses for a real hand edit.
if [ "$v" = "live" ]; then
  :
elif [ -f "variants/Mirrors.$v.daml" ]; then
  cp "variants/Mirrors.$v.daml" mirrors/daml/Mirrors.daml
else
  echo "usage: 05-variant.sh v1|v2|live"; exit 1
fi
( cd mirrors && dpm build -o ../artifacts/mirrors.dar ) 2>&1 | grep -E "Created|error" || true
cp artifacts/mirrors.dar "artifacts/mirrors-$v.dar"
( cd seed && dpm build -o ../artifacts/mirrors-seed.dar ) 2>&1 | grep -E "Created|error" || true
pkg=$(dpm inspect-dar "artifacts/mirrors-$v.dar" 2>/dev/null | grep -oE '^mirrors-1\.0\.0-[0-9a-f]{64} ' | head -1 | sed 's/mirrors-1.0.0-//;s/ //')
echo "$pkg" > "logs/pkgid-$v.txt"
echo "variant=$v mainPackageId=$pkg"
