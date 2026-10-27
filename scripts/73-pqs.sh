#!/usr/bin/env bash
# PQS rows: how a reload affects the Participant Query Store, and which clean-up works.
#
#   PQS-A  Option A, prune: three breaking reloads with PQS running, fresh re-ingest, CLI prune
#   PQS-B  Option B, reset_to_offset + version filter, as the reviewer describes it (expected: PQS crashes)
#   PQS-D  a fresh PQS re-ingest with the old DAR kept, then after it is removed
#   PQS-X  the Option B items the crashed B run cannot reach, each on its own fresh database
#   PQS-V  A, B and X again on PQS 3.5.1 and 3.6.2 (containers), against the local 3.5.7 runs
#   PQS-C  compatible (SCU) reloads, default and TransactionTreeStream datasource
#   PQS-M  one participant on two synchronizers, all parties and a single-party PQS
#   PQS-E  edge cases: empty setup after a reload, a party allocated after PQS started
#   PQS-I  a template implementing an interface from a package that is never reloaded
#   PQS-R  FRED reset with PQS attached: live, restart, late, fresh
#   PQS-S  prune at scale: 1,000, 10,000 and 50,000 archived contracts
#   PQS-L  the reviewer's Option A claims: prune target vs checkpoint, repeat prune, filter restart
#
# The CN QuickStart row (pqs/quickstart/run.sh) needs a running LocalNet and is run separately.
#
# Every row writes its numbered step logs, steps.tsv, offsets.tsv and measures.tsv to
# evidence/pqs/<stamp>/<run>/. Each row is checked against its expected ending: "RUN ... COMPLETE",
# or for B a stop on PQS dying with `key not found`. Any other ending fails the driver.
#
# usage: 73-pqs.sh            all rows
#        ROWS="A B" 73-pqs.sh only those rows
# Needs: dpm (Canton 3.5.12 sandbox), Java 21, docker, the PQS 3.5.7 jar (PQS_JAR, see pqs/lib.sh).
# Uses a throwaway postgres:16 container `fred-pqs-pg` on 127.0.0.1:5499, removed at the end.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

IMG351=europe-docker.pkg.dev/da-images/public/docker/participant-query-store:3.5.1
IMG362=europe-docker.pkg.dev/da-images/public/docker/participant-query-store:3.6.2
# Citable only from a clean checkout at a harness tag, like every other row. PQS_ALLOW_UNTAGGED=1 runs
# anyway for development, and the provenance then says so.
if [ -n "$(git status --porcelain -- . ':!evidence')" ] || ! git describe --tags --exact-match --match 'harness-*' >/dev/null 2>&1; then
  [ -n "${PQS_ALLOW_UNTAGGED:-}" ] || { echo "VOID: not a clean checkout at a harness-* tag (PQS_ALLOW_UNTAGGED=1 to run anyway, not citable)"; exit 2; }
fi
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
export PQS_LOGROOT="$PWD/evidence/pqs/$stamp"
mkdir -p "$PQS_LOGROOT"
SUMMARY="$PQS_LOGROOT/summary.tsv"; : > "$SUMMARY"
exec > >(tee "$PQS_LOGROOT/driver.log") 2>&1

provenance() {
  echo "stamp            $stamp"
  echo "git              $(git describe --tags --always --dirty 2>/dev/null) ($(git rev-parse HEAD))"
  echo "git status       $(git status --porcelain -- . ':!evidence' | wc -l | tr -d ' ') changed file(s) outside evidence/"
  echo "citable          $([ -n "${PQS_ALLOW_UNTAGGED:-}" ] && echo "no (PQS_ALLOW_UNTAGGED)" || echo yes)"
  echo "dpm              $(dpm version 2>/dev/null | head -1)"
  echo "java             $("${JAVA_HOME_21:-/opt/homebrew/opt/openjdk@21}/bin/java" -version 2>&1 | head -1)"
  local jar="${PQS_JAR:-$HOME/.dpm/cache/components/scribe/3.5.7/scribe.jar}"
  echo "pqs jar          $jar sha256=$(shasum -a 256 "$jar" 2>/dev/null | cut -d' ' -f1)"
  for i in "$IMG351" "$IMG362" postgres:16; do
    echo "image            $i $(docker image inspect -f '{{index .RepoDigests 0}}' "$i" 2>/dev/null)"
  done
  echo "fixtures         $(shasum -a 256 pqs/fixtures/*.dar | shasum -a 256 | cut -d' ' -f1) (sha256 of the DAR hashes)"
}

pg_up() {
  docker rm -f fred-pqs-pg >/dev/null 2>&1
  docker run -d --name fred-pqs-pg -e POSTGRES_PASSWORD=pw -p 127.0.0.1:5499:5432 postgres:16 >/dev/null || return 1
  for _ in $(seq 1 30); do docker exec fred-pqs-pg pg_isready -U postgres >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
# Leave nothing behind between rows, whatever the previous row did.
tidy() {
  pkill -f "scribe.jar" 2>/dev/null; docker rm -f fred-pqs-run >/dev/null 2>&1
  pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 2
}

fail=0
# row <id> <run-dir> <expect: complete|crash> <env...> -- <script>
row() {
  local id="$1" run="$2" expect="$3"; shift 3
  local -a env=(); while [ "$1" != "--" ]; do env+=("$1"); shift; done; shift
  local script="$1" out="$PQS_LOGROOT/$run.console.txt"
  echo; echo "==== $id  $run  ($(date -u +%H:%M:%S))"
  tidy; pg_up || { echo "postgres failed"; printf '%s\t%s\tFAIL\tpostgres\n' "$id" "$run" >> "$SUMMARY"; fail=1; return; }
  local t0=$SECONDS
  env "${env[@]}" bash "pqs/$script" > "$out" 2>&1; local rc=$?
  local got
  if [ "$expect" = crash ]; then
    if [ $rc -ne 0 ] && grep -q "PQS died" "$out" && grep -rqs "key not found" "$PQS_LOGROOT/$run"/*pqs-start*.log; then got=PASS; else got=FAIL; fi
  else
    if [ $rc -eq 0 ] && grep -q "COMPLETE" "$out"; then got=PASS; else got=FAIL; fi
  fi
  [ "$got" = PASS ] || fail=1
  printf '%s\t%s\t%s\texpect=%s\trc=%s\t%ss\n' "$id" "$run" "$got" "$expect" "$rc" "$((SECONDS-t0))" | tee -a "$SUMMARY"
  tail -2 "$out"
}

want() { [ -z "${ROWS:-}" ] || [[ " $ROWS " == *" $1 "* ]]; }

# Pull the version images first, so their digests are recorded in the provenance.
want V && for i in "$IMG351" "$IMG362"; do docker pull -q "$i" >/dev/null || echo "pull failed: $i"; done
echo "#### PQS rows"; provenance | tee "$PQS_LOGROOT/PROVENANCE.txt"
want A && row PQS-A A complete RUN_NAME=A -- runA.sh
want B && row PQS-B B crash    RUN_NAME=B -- runB.sh
want X && row PQS-X X complete RUN_NAME=X -- runX.sh
want D && row PQS-D D complete RUN_NAME=D -- runD.sh
if want V; then
  row PQS-V A351 complete RUN_NAME=A351 PQS_IMAGE=$IMG351 -- runA.sh
  row PQS-V B351 crash    RUN_NAME=B351 PQS_IMAGE=$IMG351 -- runB.sh
  row PQS-V X351 complete RUN_NAME=X351 PQS_IMAGE=$IMG351 -- runX.sh
  row PQS-V A362 complete RUN_NAME=A362 PQS_IMAGE=$IMG362 -- runA.sh
  row PQS-V B362 crash    RUN_NAME=B362 PQS_IMAGE=$IMG362 -- runB.sh
  row PQS-V X362 complete RUN_NAME=X362 PQS_IMAGE=$IMG362 -- runX.sh
fi
if want C; then
  row PQS-C C  complete RUN_NAME=C -- runC.sh
  row PQS-C CT complete RUN_NAME=CT "PQS_EXTRA=--pipeline-datasource TransactionTreeStream" -- runC.sh
fi
if want M; then
  row PQS-M M  complete RUN_NAME=M -- runM.sh
  row PQS-M MP complete RUN_NAME=MP "PARTY_FILTER=Alice::*" -- runM.sh
fi
want E && row PQS-E E complete RUN_NAME=E -- runE.sh
want I && row PQS-I I complete RUN_NAME=I -- runI.sh
if want R; then for c in live restart late fresh; do row PQS-R R-$c complete CASE=$c -- runR.sh; done; fi
if want S; then for n in 1000 10000 50000; do row PQS-S S-$n complete SCALE=$n -- runS.sh; done; fi
if want L; then for v in filter nofilter; do row PQS-L L-$v complete VARIANT=$v -- runL.sh; done
  # The two L variants differ only in the restart filter. Compare their measures with contract ids
  # masked and the three rows that record the filter itself left out: no output means no effect.
  lmask() { grep -v '^ids	' "$1" | grep -v -E '	(filter_line|pipeline_filter_config|restart_filter)	' \
    | sed -E 's/[0-9a-f]{12}@/C@/g; s/[0-9a-f]{40,}/CID/g'; }
  if [ -d "$PQS_LOGROOT/L-filter" ] && [ -d "$PQS_LOGROOT/L-nofilter" ]; then
    { echo "L-filter vs L-nofilter measures (ids masked, filter rows excluded):"
      diff <(lmask "$PQS_LOGROOT/L-filter/measures.tsv") <(lmask "$PQS_LOGROOT/L-nofilter/measures.tsv") && echo "IDENTICAL"
    } > "$PQS_LOGROOT/L-compare.txt"; cat "$PQS_LOGROOT/L-compare.txt"
  fi
fi

tidy; docker rm -f fred-pqs-pg >/dev/null 2>&1
echo; echo "#### summary"; cat "$SUMMARY"
[ $fail -eq 0 ] && echo "ALL PQS ROWS AS EXPECTED" || echo "SOME PQS ROWS NOT AS EXPECTED"
exit $fail
