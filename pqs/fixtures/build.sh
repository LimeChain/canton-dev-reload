#!/usr/bin/env bash
# Build the mirrors generations for the A/B comparison into ./<opt>-g<N>.dar.
# Sources are generated from the repo's mirrors/ and variants/ into src/; nothing else is written.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
build() {  # opt gen type version
  local opt=$1 n=$2 ty=$3 ver=$4 d="src/$1-g$2"
  rm -rf "$d"; mkdir -p "$d/daml"
  sed "s/^version: 1.0.0$/version: $ver/" "$R/mirrors/daml.yaml" > "$d/daml.yaml"
  sed "s/^type Val = Text$/type Val = $ty/" "$R/variants/Mirrors.v1.daml" > "$d/daml/Mirrors.daml"
  cat >> "$d/daml/Mirrors.daml" <<'DAML'

instance DemoVal Bool where
  demoDefault = True
  nameOf _    = "Bool"

instance DemoVal Decimal where
  demoDefault = 1.5
  nameOf _    = "Decimal"
DAML
  printf 'sdk-version: 3.5.5\npackages:\n- .\n' > "$d/multi-package.yaml"
  (cd "$d" && dpm build -o "../../$opt-g$n.dar") > "build-$opt-g$n.log" 2>&1 || { echo "BUILD FAILED $opt-g$n"; tail -20 "build-$opt-g$n.log"; exit 1; }
  local id; id=$(dpm inspect-dar "$opt-g$n.dar" 2>/dev/null | grep -oE "^mirrors-$ver-[0-9a-f]{64} " | head -1 | sed "s/mirrors-$ver-//;s/ //")
  printf '%s\t%s\t%s\t%s\t%s\n' "$opt-g$n" "$ty" "$ver" "$id" "$(grep -c "type Val = $ty" "$d/daml/Mirrors.daml")" | tee -a fixtures.tsv
}
: > fixtures.tsv
build A 1 Text 1.0.0; build A 2 Int 1.0.0; build A 3 Bool 1.0.0; build A 4 Decimal 1.0.0
build B 1 Text 1.0.0; build B 2 Int 1.0.1; build B 3 Bool 1.0.2; build B 4 Decimal 1.0.3
