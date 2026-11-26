#!/usr/bin/env bash
# Multi-node rows (docs/test-plan-multinode-purge.md): two participants (provider, user) on two
# synchronizers. Each row runs in its own fresh in-memory Canton process: console/mn-lib.canton
# builds the fixture, then console/mn-<row>.canton runs the row and prints ASSERT/EXPECT_CODE/VERDICT.
#
# usage: 74-multinode.sh ROW [ROW...]     e.g. 74-multinode.sh mn1 mn2
# EXPLORATORY until committed and tagged: no provenance header yet, so logs go to logs/, not evidence/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

JAR="$HOME/.dpm/cache/components/canton-open-source/3.5.12/lib/canton-open-source-3.5.12.jar"
[ -f "$JAR" ] || { echo "missing Canton jar: $JAR"; exit 1; }
for v in v1 v2; do [ -f "artifacts/shared-$v.dar" ] || { echo "missing artifacts/shared-$v.dar"; exit 1; }; done
export MN_V1_DAR="$ROOT/artifacts/shared-v1.dar" MN_V2_DAR="$ROOT/artifacts/shared-v2.dar"

rc=0
for row in "$@"; do
  src="console/mn-$row.canton"; [ -f "$src" ] || { echo "no such row: $src"; rc=1; continue; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  export MN_ROW="$row"
  script="logs/mn-$row.run.canton"; log="logs/${stamp}__MN__$row.log"
  cat console/mn-lib.canton "$src" > "$script"; : > "logs/mn-$row.canton.log"
  export MN_H2_DIR="$ROOT/logs/mn-h2-$row"; rm -rf "$MN_H2_DIR"; mkdir -p "$MN_H2_DIR"
  banner "row $row  ->  $log"
  with_timeout "${MN_TIMEOUT:-600}" java -jar "$JAR" run "$script" -c canton/multinode.conf \
    --log-file-name "logs/mn-$row.canton.log" > "$log" 2>&1 < /dev/null
  r=$?
  grep -E "^(SETUP|NOTE|ASSERT|EXPECT_CODE|VERDICT|TIME)" "$log" || true
  # The console only throws "Command execution failed."; decoded codes go to the Canton log. Match
  # only the Canton log, and only the decoded form CODE(category,correlation): the row log carries
  # the EXPECT_* lines themselves, so grepping it would match every code trivially.
  canton_log="logs/mn-$row.canton.log"
  has_code() { grep -qE "$1\([0-9]+,[0-9a-f]+\)|code = '$1'" "$canton_log" 2>/dev/null; }
  while read -r _ step code; do
    if has_code "$code"; then
      printf 'ASSERT code-%-14s PASS  %s present\n' "$step" "$code"
    else
      printf 'ASSERT code-%-14s FAIL  %s not found\n' "$step" "$code"; r=1
    fi
  done < <(grep "^EXPECT_CODE" "$log")
  while read -r _ step code; do
    if has_code "$code"; then
      printf 'ASSERT nocode-%-12s FAIL  %s present\n' "$step" "$code"; r=1
    else
      printf 'ASSERT nocode-%-12s PASS  %s absent\n' "$step" "$code"
    fi
  done < <(grep "^EXPECT_NO_CODE" "$log")
  grep -q "^VERDICT PASS" "$log" || { echo "row $row: no VERDICT PASS (exit $r), see $log"; r=1; }
  [ "$r" -eq 0 ] || rc=1
done
exit $rc
