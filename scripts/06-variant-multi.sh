#!/usr/bin/env bash
# Build the two-package closure (items -> holders) plus its client script (seedab) at a chosen
# variant, WITHOUT mutating tracked sources.
#
# Why all three packages need variants: changing Item.label from Text to Int breaks the
# dependents at compile time, not just at runtime.
#   multi/holders/daml/Holders.daml  declares `choice PeekItem : Text` returning `i.label`
#   multi/seedab/daml/SeedAB.daml    builds `Item { label = "first" }` and renders `<> l`
# So an Int variant of items alone will not compile, and a closure fixture set must cover the
# dependent and its client script together. That is precisely the property M1/M2 demonstrate.
#
# Generated projects sit at depth 2 (.gen-multi-$v/items), matching multi/items, so the tracked
# relative data-dependency ../../artifacts/items.dar resolves to the repo-root artifacts dir
# with no rewriting.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

v="${1:-}"
case "$v" in
  v1|v2) ;;
  *) echo "usage: 06-variant-multi.sh v1|v2" >&2; exit 1 ;;
esac

gen=".gen-multi-$v"
rm -rf "$gen"
mkdir -p "$gen/items/daml" "$gen/holders/daml" "$gen/seedab/daml"

cp multi/items/daml.yaml    "$gen/items/daml.yaml"
cp multi/holders/daml.yaml  "$gen/holders/daml.yaml"
cp multi/seedab/daml.yaml   "$gen/seedab/daml.yaml"
cp "variants/Items.$v.daml"   "$gen/items/daml/Items.daml"
cp "variants/Holders.$v.daml" "$gen/holders/daml/Holders.daml"
cp "variants/SeedAB.$v.daml"  "$gen/seedab/daml/SeedAB.daml"

# A local single-entry manifest stops DPM's upward search for multi-package.yaml, which would
# otherwise find the repo-root one and refuse to build a directory it does not list.
for p in items holders seedab; do
  printf 'sdk-version: 3.5.5\npackages:\n- .\n' > "$gen/$p/multi-package.yaml"
done

build_pkg() {
  local dir="$1" out="$2" log rc
  log="$( cd "$dir" && dpm build -o "$out" 2>&1 )"; rc=$?
  printf '%s\n' "$log" | grep -E "Created|error" || true
  if [ "$rc" -ne 0 ]; then
    echo "06-variant-multi: build FAILED in $dir" >&2
    printf '%s\n' "$log" | tail -25 >&2
    return 1
  fi
}

pkgid() {  # dar, package-name
  dpm inspect-dar "$1" 2>/dev/null \
    | grep -oE "^$2-1\.0\.0-[0-9a-f]{64} " | head -1 | sed "s/$2-1.0.0-//;s/ //"
}

# Dependency order is load-bearing: holders data-depends on artifacts/items.dar, so items must be
# written to that exact path first, and seedab depends on both.
build_pkg "$gen/items"   ../../artifacts/items.dar   || exit 1
build_pkg "$gen/holders" ../../artifacts/holders.dar || exit 1
build_pkg "$gen/seedab"  ../../artifacts/seedab.dar  || exit 1

for p in items holders seedab; do
  cp "artifacts/$p.dar" "artifacts/$p-$v.dar"
  id="$(pkgid "artifacts/$p-$v.dar" "$p")"
  [ -n "$id" ] || { echo "06-variant-multi: could not read main package id for $p" >&2; exit 1; }
  echo "$id" > "logs/pkgid-$p-$v.txt"
  echo "$p=$id"
done

{
  echo "variant=$v"
  for p in items holders seedab; do
    src="variants/$(printf '%s' "$p" | awk '{print toupper(substr($0,1,1)) substr($0,2)}').$v.daml"
    [ "$p" = "seedab" ] && src="variants/SeedAB.$v.daml"
    echo "${p}_source=$src"
    echo "${p}_blob=$(git hash-object "$src" 2>/dev/null || echo unknown)"
    echo "${p}_pkgid=$(cat "logs/pkgid-$p-$v.txt")"
  done
} > "logs/variant-multi-$v.provenance"

echo "multi variant=$v built from $gen"
