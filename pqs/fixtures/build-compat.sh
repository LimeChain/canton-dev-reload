#!/usr/bin/env bash
# Build compatible (SCU) upgrades of A-g1 (mirrors 1.0.0, value : Text) into ./C-g<N>.dar:
#   C-g2 mirrors 1.0.1: adds note : Optional Text and a Bump choice.
#   C-g3 mirrors 1.0.2: keeps both, adds tag : Optional Int.
# Same source and DemoVal instances as build.sh; the repo is never written to.
set -euo pipefail
cd "$(dirname "$0")"
R="$(cd "$(dirname "$0")/../.." && pwd)"
build() {  # gen version extra-fields
  local n=$1 ver=$2 fields=$3 d="src/C-g$1"
  rm -rf "$d"; mkdir -p "$d/daml"
  sed "s/^version: 1.0.0$/version: $ver/" "$R/mirrors/daml.yaml" > "$d/daml.yaml"
  FIELDS="$fields" python3 -c '
import os,sys
s=open(sys.argv[1]).read()
old="    value : Val\n  where\n    signatory owner\n"
assert old in s
new="    value : Val\n"+os.environ["FIELDS"]+"  where\n    signatory owner\n\n    choice Bump : ContractId Mirror\n      controller owner\n      do create this with note = Some \"bumped\"\n"
print(s.replace(old,new),end="")' "$R/variants/Mirrors.v1.daml" > "$d/daml/Mirrors.daml"
  cat >> "$d/daml/Mirrors.daml" <<'DAML'

instance DemoVal Bool where
  demoDefault = True
  nameOf _    = "Bool"

instance DemoVal Decimal where
  demoDefault = 1.5
  nameOf _    = "Decimal"
DAML
  printf 'sdk-version: 3.5.5\npackages:\n- .\n' > "$d/multi-package.yaml"
  (cd "$d" && dpm build -o "../../C-g$n.dar") > "build-C-g$n.log" 2>&1 || { echo "BUILD FAILED C-g$n"; tail -20 "build-C-g$n.log"; exit 1; }
  local id; id=$(dpm inspect-dar "C-g$n.dar" 2>/dev/null | grep -oE "^mirrors-$ver-[0-9a-f]{64} " | head -1 | sed "s/mirrors-$ver-//;s/ //")
  [ -n "$id" ] || { echo "no package id for C-g$n"; exit 1; }
  sed -i '' "/^C-g$n	/d" fixtures.tsv
  printf '%s\t%s\t%s\t%s\t%s\n' "C-g$n" "Text+compat" "$ver" "$id" "$(grep -c 'choice Bump' "$d/daml/Mirrors.daml")" | tee -a fixtures.tsv
}
build 2 1.0.1 '    note : Optional Text
'
build 3 1.0.2 '    note : Optional Text
    tag : Optional Int
'
