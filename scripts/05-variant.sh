#!/usr/bin/env bash
# Build a model variant WITHOUT mutating tracked sources.
#
# This script used to `cp variants/Mirrors.$v.daml mirrors/daml/Mirrors.daml`, which left a
# tracked source modified for the whole run. Evidence runs assert a clean working tree, so that
# copy would have failed every run it was meant to validate. Instead we materialise a throwaway
# project under .gen-mirrors-$v/ and build there; mirrors/ and seed/ are never written to.
#
# Generated projects sit at the SAME directory depth as the originals, so relative paths resolve
# identically with no rewriting: seed/daml.yaml refers to ../artifacts/mirrors.dar, and
# .gen-seed-$v/ is likewise one level below the repo root. Same for `dpm build -o ../artifacts/...`.
#
# daml.yaml is copied verbatim -- holding name and version constant while the package ID moves is
# the whole point of the POC.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

v="${1:-}"
case "$v" in
  v1|v2)
    src="variants/Mirrors.$v.daml"
    ;;
  live)
    # Builds whatever the developer has actually typed into the tracked source. That dirties the
    # working tree by design, so a `live` build can never back an evidence run -- env-stamp.sh
    # will refuse it. Presentation mode only.
    src="mirrors/daml/Mirrors.daml"
    ;;
  *)
    echo "usage: 05-variant.sh v1|v2|live" >&2
    exit 1
    ;;
esac
[ -f "$src" ] || { echo "05-variant: missing source $src" >&2; exit 1; }

gen_mirrors=".gen-mirrors-$v"
gen_seed=".gen-seed-$v"
rm -rf "$gen_mirrors" "$gen_seed"
mkdir -p "$gen_mirrors/daml" "$gen_seed/daml"

cp mirrors/daml.yaml       "$gen_mirrors/daml.yaml"
cp "$src"                  "$gen_mirrors/daml/Mirrors.daml"
[ -f mirrors/.dlint.yaml ] && cp mirrors/.dlint.yaml "$gen_mirrors/.dlint.yaml"
cp seed/daml.yaml          "$gen_seed/daml.yaml"
cp seed/daml/Seed.daml     "$gen_seed/daml/Seed.daml"

# Each generated project gets its own single-entry multi-package.yaml. DPM searches upward for
# one, finds the repo-root manifest, and refuses to build a directory that manifest does not
# list -- "DPM did not provide information for package at ...". A local manifest stops that
# search and makes the generated project self-contained. (--enable-multi-package=no does NOT
# help: the resolution failure happens before that flag is consulted.)
for d in "$gen_mirrors" "$gen_seed"; do
  printf 'sdk-version: 3.5.5\npackages:\n- .\n' > "$d/multi-package.yaml"
done

# Build in dependency order: seed/daml.yaml data-depends on ../artifacts/mirrors.dar, so the
# model must exist before the script package is built.
build_pkg() {
  local dir="$1" out="$2" log rc
  log="$( cd "$dir" && dpm build -o "$out" 2>&1 )"; rc=$?
  printf '%s\n' "$log" | grep -E "Created|error" || true
  if [ "$rc" -ne 0 ]; then
    echo "05-variant: build FAILED in $dir" >&2
    printf '%s\n' "$log" | tail -20 >&2
    return 1
  fi
}

build_pkg "$gen_mirrors" ../artifacts/mirrors.dar || exit 1
cp artifacts/mirrors.dar "artifacts/mirrors-$v.dar"
build_pkg "$gen_seed" ../artifacts/mirrors-seed.dar || exit 1

pkg=$(dpm inspect-dar "artifacts/mirrors-$v.dar" 2>/dev/null \
      | grep -oE '^mirrors-1\.0\.0-[0-9a-f]{64} ' | head -1 | sed 's/mirrors-1.0.0-//;s/ //')
[ -n "$pkg" ] || { echo "05-variant: could not read main package id from artifacts/mirrors-$v.dar" >&2; exit 1; }
echo "$pkg" > "logs/pkgid-$v.txt"

# Provenance for the evidence stamp: which source file was actually compiled, and its content
# hash. env-stamp.sh separately asserts the tree is clean, so for v1/v2 this hash is necessarily
# the committed blob -- recording it means the evidence names its inputs rather than only
# asserting that nothing was dirty.
{
  echo "variant=$v"
  echo "mirrors_source=$src"
  echo "mirrors_blob=$(git hash-object "$src" 2>/dev/null || echo unknown)"
  echo "mirrors_pkgid=$pkg"
} > "logs/variant-$v.provenance"

echo "variant=$v mainPackageId=$pkg builtFrom=$gen_mirrors source=$src"
