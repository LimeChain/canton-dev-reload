#!/usr/bin/env bash
# Evidence-safe helpers for the PQS A/B comparison.
#
# Every console call, SQL call and PQS start writes its own full log under $PQS_LOGROOT/$RUN/, numbered so
# nothing is overwritten. Every step records its exit code against an expectation (ok|fail) in
# steps.tsv, and an unmet expectation stops the run. Waits are bounded and fail fast when PQS dies.
# Usage: RUN=<name>; . lib.sh   (assign RUN first; a prefix assignment would not persist)
set -uo pipefail
export LC_ALL=C
AB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$AB/fixtures"
: "${RUN:?RUN must be set}"
LOGDIR="${PQS_LOGROOT:-$AB/logs}/$RUN"
mkdir -p "$LOGDIR"
: > "$LOGDIR/steps.tsv"; : > "$LOGDIR/offsets.tsv"; : > "$LOGDIR/measures.tsv"
# PQS needs Java 21. PQS_JAR is the local PQS 3.5.7 jar (dpm caches it on first `dpm pqs`).
export JAVA_HOME="${JAVA_HOME_21:-/opt/homebrew/opt/openjdk@21}"; export PATH="$JAVA_HOME/bin:$PATH"
JAR="${PQS_JAR:-$HOME/.dpm/cache/components/scribe/3.5.7/scribe.jar}"
PG=fred-pqs-pg
N=0
now() { python3 -c 'import time;print("%.3f"%time.time())'; }
# nextlog <name> : sets LOG to the next numbered log path (no subshell, so the counter persists).
nextlog() { N=$((N+1)); LOG="$(printf '%s/%02d-%s.log' "$LOGDIR" "$N" "$1")"; }
die() { echo "STOP [$RUN] $*" | tee -a "$LOGDIR/steps.tsv" >&2; exit 1; }

# step <name> <ok|fail> <cmd...> : run cmd, full output to its own log, check the exit code.
step() {
  local name="$1" want="$2"; shift 2
  nextlog "$name"; local log="$LOG"
  local t0 t1 rc; t0=$(now)
  "$@" > "$log" 2>&1; rc=$?
  t1=$(now)
  local got=ok; [ "$rc" -ne 0 ] && got=fail
  printf '%s\t%s\twant=%s\tgot=%s\trc=%s\t%.3fs\t%s\n' "$N" "$name" "$want" "$got" "$rc" \
    "$(python3 -c "print($t1-$t0)")" "$(basename "$log")" >> "$LOGDIR/steps.tsv"
  LAST_LOG="$log"
  [ "$got" = "$want" ] || die "step $name: wanted $want, got $got (rc=$rc), see $log"
}

# Value lines ("T key=value") printed by console scripts, read back from the step's log.
tval() { sed -n "s/^T $1=//p" "$LAST_LOG" | tail -1; }
offset() { printf '%s\t%s\n' "$1" "$2" >> "$LOGDIR/offsets.tsv"; }
measure() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LOGDIR/measures.tsv"; }

# ---- console (common.sc + a script, env passed through) --------------------------------------
_con() {
  cat "$AB/common.sc" "$1" > "$LOGDIR/.run.canton"
  dpm canton-console -C canton.features.enable-preview-commands=yes \
    --bootstrap "$LOGDIR/.run.canton" --no-tty < /dev/null
}
con() { local name="$1" want="$2" script="$3"; step "$name" "$want" _con "$AB/$script"; }

# ---- SQL ---------------------------------------------------------------------------------------
_sql() {  # db sql [user]
  local db="$1" q="$2" user="${3:-postgres}"
  if [ "$user" = postgres ]; then
    docker exec "$PG" psql -v ON_ERROR_STOP=1 -U postgres -d "$db" -tA -F' | ' -c "$q"
  else
    docker exec -e PGPASSWORD=reader "$PG" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$user" -d "$db" -tA -c "$q"
  fi
}
sql() { local name="$1" want="$2"; shift 2; step "$name" "$want" _sql "$@"; }
# sqlv <name> <db> <sql> : run and set VAL to the single value (logged like any other step).
# Sets a variable rather than echoing: calling it inside $(...) would run it in a subshell, losing
# the step counter (so the next log would overwrite this one) and swallowing a die().
sqlv() { sql "$1" ok "$2" "$3"; VAL="$(grep -v '^NOTICE' "$LAST_LOG" | tail -1)"; }
# mv_ <tag> <key> <name> <db> <sql> : sqlv then record the value as a measurement.
mv_() { sqlv "$3" "$4" "$5"; measure "$1" "$2" "$VAL"; }

# ---- sandbox -------------------------------------------------------------------------------------
_sandbox_start() {
  pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 3
  nohup dpm sandbox --no-tty > "$1" 2>&1 < /dev/null &
  for _ in $(seq 1 60); do grep -q "Canton sandbox is ready" "$1" && return 0; sleep 2; done
  echo "sandbox not ready within 120s"; return 1
}
sandbox_start() { nextlog sandbox; local log="$LOG"; _sandbox_start "$log" > "$log.status" 2>&1 \
  || die "sandbox failed, see $log"; echo -e "$N\tsandbox\twant=ok\tgot=ok\t-\t-\t$(basename "$log")" >> "$LOGDIR/steps.tsv"; }
sandbox_stop() { pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 2; }

# ---- PQS -----------------------------------------------------------------------------------------
PQS_PID=""; PQS_LOG=""
createdb_fresh() { docker exec "$PG" psql -U postgres -tAc "drop database if exists $1 with (force)" >/dev/null 2>&1
  step "createdb-$1" ok docker exec "$PG" createdb -U postgres "$1"; }
# A contract filter goes in PQS_FILTER, passed as SCRIBE_PIPELINE_FILTER_CONTRACTS: on the command
# line, --pipeline-filter-contracts truncates any value containing '=' (">=1.0.1" arrives as "1.0.1").
pqs_start() {  # db [extra flags...]
  local db="$1"; shift
  nextlog "pqs-start-$db"; PQS_LOG="$LOG"
  # PQS_IMAGE=<image> runs that PQS version in a container instead of the local 3.5.7 jar; it
  # reaches the sandbox and Postgres on the host through host.docker.internal.
  local host=localhost; local -a cmd=(java -jar "$JAR")
  if [ -n "${PQS_IMAGE:-}" ]; then
    host=host.docker.internal
    docker rm -f fred-pqs-run >/dev/null 2>&1
    cmd=(docker run --rm --name fred-pqs-run -e SCRIBE_PIPELINE_FILTER_CONTRACTS="${PQS_FILTER:-*}" "$PQS_IMAGE")
  fi
  SCRIBE_PIPELINE_FILTER_CONTRACTS="${PQS_FILTER:-*}" "${cmd[@]}" pipeline ledger postgres-document \
    --source-ledger-host "$host" --source-ledger-port 6865 \
    --target-postgres-host "$host" --target-postgres-port 5499 --target-postgres-database "$db" \
    --target-postgres-username postgres --target-postgres-password pw \
    --pipeline-ledger-start Oldest --pipeline-ledger-stop Never --health-port 18080 "$@" \
    > "$PQS_LOG" 2>&1 < /dev/null &
  PQS_PID=$!
  printf '%s\tpqs-start-%s\twant=ok\tgot=started\tpid=%s\t-\t%s\t%s\n' "$N" "$db" "$PQS_PID" "$(basename "$PQS_LOG")" "filter=${PQS_FILTER:-*} image=${PQS_IMAGE:-local-3.5.7} $*" >> "$LOGDIR/steps.tsv"
}
pqs_alive() { [ -n "$PQS_PID" ] && kill -0 "$PQS_PID" 2>/dev/null; }
pqs_stop() { if pqs_alive; then kill "$PQS_PID"; for _ in $(seq 1 20); do pqs_alive || break; sleep 0.5; done; fi
  pqs_alive && kill -9 "$PQS_PID"; [ -n "${PQS_IMAGE:-}" ] && docker rm -f fred-pqs-run >/dev/null 2>&1; PQS_PID=""; }
# wait_pqs_offset <db> <offset> [timeout] : until PQS's latest checkpoint reaches offset. Pass the
# offset of the last submitted TRANSACTION (T LASTTX), not the ledger end: uploads and topology
# changes move the ledger end without ever producing a PQS checkpoint.
wait_pqs_offset() {
  local db="$1" off="$2" lim="${3:-90}" t0; t0=$(now)
  for _ in $(seq 1 "$lim"); do
    pqs_alive || die "PQS died while waiting for offset $off, see $PQS_LOG"
    local cp; cp=$(_sql "$db" "select (latest_checkpoint()).offset" 2>/dev/null | tail -1)
    if [ -n "$cp" ] && [ "$cp" -ge "$off" ] 2>/dev/null; then
      printf '%s\twait-%s-%s\twant=ok\tgot=ok\tcheckpoint=%s\t%.3fs\t-\n' "$N" "$db" "$off" "$cp" \
        "$(python3 -c "print($(now)-$t0)")" >> "$LOGDIR/steps.tsv"; return 0; fi
    sleep 1
  done
  die "PQS did not reach offset $off within ${lim}s, see $PQS_LOG"
}

# try_wait_pqs_offset <db> <offset> [timeout] : like wait_pqs_offset, but an OUTCOME, not a setup
# failure. Sets WAIT_RESULT to caught-up | pqs-crashed | timeout and records it; never stops the run.
try_wait_pqs_offset() {
  local db="$1" off="$2" lim="${3:-90}" t0; t0=$(now); WAIT_RESULT=timeout
  for _ in $(seq 1 "$lim"); do
    if ! pqs_alive; then WAIT_RESULT=pqs-crashed; break; fi
    local cp; cp=$(_sql "$db" "select (latest_checkpoint()).offset" 2>/dev/null | tail -1)
    if [ -n "$cp" ] && [ "$cp" -ge "$off" ] 2>/dev/null; then WAIT_RESULT=caught-up; break; fi
    sleep 1
  done
  printf '%s\ttry-wait-%s-%s\twant=outcome\tgot=%s\t-\t%.3fs\t%s\n' "$N" "$db" "$off" "$WAIT_RESULT" \
    "$(python3 -c "print($(now)-$t0)")" "$(basename "$PQS_LOG")" >> "$LOGDIR/steps.tsv"
}
# pqs_crash_cause : first fatal cause line from the current PQS log.
pqs_crash_cause() { grep -m1 -oE 'cause="[^"]{0,160}' "$PQS_LOG" | sed 's/^cause="//'; }
