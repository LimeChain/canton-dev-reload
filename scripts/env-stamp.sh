#!/usr/bin/env bash
# Emit the provenance header for an evidence run, and refuse the run if provenance cannot be
# established. Sourced or executed by the drivers; writes to stdout so it lands in the run log.
#
# WHY A TAG AND NOT HEAD: evidence is committed per row, so HEAD moves. After the first row's
# evidence commit, `git rev-parse HEAD` names that evidence commit, not the harness that
# produced the run. Provenance is therefore anchored to the `harness-vN` tag, and every row of a
# matrix must carry the same HARNESS_REV.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# Must source lib.sh: it pins JAVA_HOME to an OpenJDK. Without it the stamp records whatever JVM
# happens to be on PATH (a temurin-17 here) rather than the one the harness actually runs on,
# which is exactly the kind of mislabelling this rebuild exists to remove.
. scripts/lib.sh

HARNESS_TAG="${POC_HARNESS_TAG:-harness-v1}"

echo "==== ENVIRONMENT ===================================================="
echo "utc              $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host             $(uname -srm)"
echo "dpm              $(dpm --version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
echo "java             $(java -version 2>&1 | head -1)"
echo "java_home        ${JAVA_HOME:-<unset>}"
# The running jar path carries the Canton version authoritatively; cheaper than a console probe.
# macOS pgrep has no -a, so read the command line from ps instead.
_sbpid="$(sandbox_pid)"
echo "sandbox_pid      ${_sbpid:-<none>}"
if [ -n "$_sbpid" ]; then
  echo "canton_jar       $(ps -p "$_sbpid" -o command= 2>/dev/null | grep -oE 'canton-open-source-[0-9.]+\.jar' | head -1 || echo '<unknown>')"
else
  echo "canton_jar       <sandbox not running>"
fi

echo "==== PROVENANCE ====================================================="
echo "head             $(git rev-parse HEAD 2>/dev/null || echo '<no commits>')"

prov_rc=0
if git rev-parse -q --verify "refs/tags/$HARNESS_TAG" >/dev/null 2>&1; then
  echo "harness_tag      $HARNESS_TAG"
  echo "HARNESS_REV      $(git rev-parse "$HARNESS_TAG")"

  # (1) nothing COMMITTED outside evidence/ has changed since the tag
  if git diff --quiet "$HARNESS_TAG" HEAD -- . ':(exclude)evidence'; then
    echo "assert_committed PASS  no committed change outside evidence/ since $HARNESS_TAG"
  else
    echo "assert_committed FAIL  committed changes outside evidence/ since $HARNESS_TAG:"
    git diff --name-only "$HARNESS_TAG" HEAD -- . ':(exclude)evidence' | sed 's/^/                   /'
    prov_rc=1
  fi

  # (2) nothing UNCOMMITTED outside evidence/ -- no exclusions beyond evidence/ itself, which is
  # only possible because the variant builders write to gitignored .gen-* trees instead of
  # copying over tracked sources.
  dirty="$(git status --porcelain -- . ':(exclude)evidence')"
  if [ -z "$dirty" ]; then
    echo "assert_clean     PASS  working tree clean outside evidence/"
  else
    echo "assert_clean     FAIL  uncommitted changes outside evidence/:"
    printf '%s\n' "$dirty" | sed 's/^/                   /'
    prov_rc=1
  fi
else
  echo "harness_tag      <$HARNESS_TAG does not exist>"
  echo "HARNESS_REV      <untagged>"
  echo "assert_committed SKIP  tag missing - this run is NOT evidence-grade"
  echo "assert_clean     SKIP  tag missing - this run is NOT evidence-grade"
  prov_rc=2
fi

# Which source each generated project was actually compiled from. env-stamp asserts the tree is
# clean, so for v1/v2 these hashes are necessarily the committed blobs -- recording them means
# the log names its inputs rather than only asserting nothing was dirty.
echo "==== INPUTS ========================================================="
for f in logs/variant-*.provenance; do
  [ -f "$f" ] || continue
  sed "s|^|$(basename "$f" .provenance)  |" "$f"
done
for d in artifacts/*.dar; do
  [ -f "$d" ] || continue
  printf 'dar %-34s %s\n' "$(basename "$d")" "$(shasum -a 256 "$d" | cut -c1-64)"
done
echo "====================================================================="

exit "$prov_rc"
