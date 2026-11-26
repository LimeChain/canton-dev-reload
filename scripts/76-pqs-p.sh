#!/usr/bin/env bash
# PQS-P (Q8): does a repair.purge leave PQS holding the purged contracts as ACTIVE (purge emits no
# archive event), and which clean-up leaves PQS consistent and running?
#   capture  PQS on pqs_live (provider, from Oldest) across the coordinated reload + v2 setup; stop.
#   snapshot clone pqs_live -> pqs_a (createdb -T), fingerprints compared before any change.
#   (a)  row delete: in pqs_a delete active rows of the old package, restart PQS on pqs_a
#   (b1) full re-ingest: fresh pqs_b1 from Oldest
#   (b2) ACS start: fresh pqs_b2 from Latest
# Each branch: postconditions recorded independently, then one more v2 transaction must be ingested.
# EXPLORATORY until committed and tagged; output under logs/pqsp/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh
TAG=pqsp; . scripts/mn-daemon-lib.sh
J21=/opt/homebrew/opt/openjdk@21/bin/java
PQS_JAR="$HOME/.dpm/cache/components/scribe/3.5.7/scribe.jar"
PG=fred-pqs-pg; rc=0; PQS_PID=""
RES="$D_DIR/results.tsv"; : > "$RES"
res() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$RES"; }
chk() { local tag="$1" name="$2" got="$3" want="$4"
  if [ "$got" = "$want" ]; then echo "ASSERT $tag.$name PASS got=$got want=$want"; else echo "ASSERT $tag.$name FAIL got=$got want=$want"; rc=1; fi
  res "$tag" "$name" "$got"; }

q() { docker exec "$PG" psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -tA -c "$2"; }
active_pkg() { q "$1" "select (select count(*) from active('shared:Shared:Own') where package_id='$2') + (select count(*) from active('shared:Shared:Shared') where package_id='$2')"; }
history_pkg() { q "$1" "select count(*) from __contracts c join __packages p on p.pk=c.package_pk where p.id='$2'"; }
ckpt() { q "$1" "select coalesce((select (latest_checkpoint()).offset)::text, '-')" 2>/dev/null; }
fingerprint() { echo "$(q "$1" "select md5(string_agg(contract_id||':'||coalesce(archived_at_ix::text,'-'), ',' order by contract_id)) from __contracts")@$(ckpt "$1")"; }

pqs_start() {  # db start-mode
  PQS_LOG="$D_DIR/pqs-$1.log"
  "$J21" -jar "$PQS_JAR" pipeline ledger postgres-document \
    --source-ledger-host localhost --source-ledger-port 9865 \
    --target-postgres-host localhost --target-postgres-port 5499 --target-postgres-database "$1" \
    --target-postgres-username postgres --target-postgres-password pw \
    --pipeline-ledger-start "$2" --pipeline-ledger-stop Never --health-port 18080 >> "$PQS_LOG" 2>&1 < /dev/null &
  PQS_PID=$!; echo "pqs started db=$1 start=$2 pid=$PQS_PID"; }
pqs_alive() { [ -n "$PQS_PID" ] && kill -0 "$PQS_PID" 2>/dev/null; }
pqs_stop() { pqs_alive && kill "$PQS_PID"; for _ in $(seq 1 20); do pqs_alive || break; sleep 0.5; done; pqs_alive && kill -9 "$PQS_PID"; PQS_PID=""; }
# wait_for <timeout> <desc> <cmd...> : until cmd succeeds; reports outcome, never exits
wait_for() { local lim="$1" desc="$2"; shift 2
  for _ in $(seq 1 "$lim"); do "$@" >/dev/null 2>&1 && { echo "WAIT $desc ok"; return 0; }; pqs_alive || { echo "WAIT $desc pqs-died"; return 2; }; sleep 1; done
  echo "WAIT $desc timeout"; return 1; }
ckpt_ge() { local c; c=$(ckpt "$1"); [ "$c" != "-" ] && [ -n "$c" ] && [ "$c" -ge "$2" ]; }
active_eq() { [ "$(active_pkg "$1" "$2")" = "$3" ]; }
no_pkg_errors() { ! grep -qE "No package|UnknownDamlPackage" "$PQS_LOG"; }

# ---- setup ----------------------------------------------------------------------------------
docker rm -f "$PG" >/dev/null 2>&1
docker run -d --name "$PG" -e POSTGRES_PASSWORD=pw -p 127.0.0.1:5499:5432 postgres:16 >/dev/null || exit 1
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
pkill -f scribe.jar 2>/dev/null
mn_daemon_start || exit 1
V1="$MN_V1_PKG"; V2="$MN_V2_PKG"

banner "capture: PQS on pqs_live across the reload"
q postgres "create database pqs_live" >/dev/null
pqs_start pqs_live Oldest
wait_for 120 "live-ingests-v1" active_eq pqs_live "$V1" 3 || rc=1
chk capture v1ActiveBefore "$(active_pkg pqs_live "$V1")" 3
RCON_TIMEOUT=400 rcon reload console/pqsp-reload.canton || rc=1
wait_for 120 "live-ingests-v2" active_eq pqs_live "$V2" 3 || rc=1
chk capture pqsAliveAfterReload "$(pqs_alive && echo yes || echo no)" yes
# THE question: purge emits no archive, so PQS still reports the purged v1 contracts as active.
res capture v1ActiveAfterPurge "$(active_pkg pqs_live "$V1")"
res capture v2Active "$(active_pkg pqs_live "$V2")"
res capture checkpoint "$(ckpt pqs_live)"
pqs_stop
BASE_V2="$(active_pkg pqs_live "$V2")"; BASE_CKPT="$(ckpt pqs_live)"

banner "snapshot: pqs_live -> pqs_a"
q postgres "create database pqs_a template pqs_live" >/dev/null
q postgres "create database pqs_c template pqs_live" >/dev/null
chk snapshot identicalC "$( [ "$(fingerprint pqs_live)" = "$(fingerprint pqs_c)" ] && echo yes || echo no)" yes
chk snapshot identical "$( [ "$(fingerprint pqs_live)" = "$(fingerprint pqs_a)" ] && echo yes || echo no)" yes

# branch_post <tag> <db> : the shared postconditions, then one more v2 tx must arrive
branch_post() { local tag="$1" db="$2"
  chk "$tag" v1Active "$(active_pkg "$db" "$V1")" 0
  chk "$tag" v2Active "$(active_pkg "$db" "$V2")" "$BASE_V2"
  res "$tag" v1History "$(history_pkg "$db" "$V1")"
  res "$tag" v2History "$(history_pkg "$db" "$V2")"
  rcon "tx-$tag" console/pqsp-tx.canton >/dev/null || rc=1
  local off; off="$(sed -n 's/^T OFFSET=//p' "$D_DIR/$RNAME.out")"
  wait_for 60 "$tag-ingests-new-tx" ckpt_ge "$db" "$off"
  chk "$tag" checkpointPastNewTx "$(ckpt_ge "$db" "$off" && echo yes || echo no)" yes
  chk "$tag" v2ActiveAfterTx "$(active_pkg "$db" "$V2")" "$((BASE_V2 + 1))"
  chk "$tag" pqsAlive "$(pqs_alive && echo yes || echo no)" yes
  chk "$tag" noPackageErrors "$(no_pkg_errors && echo yes || echo no)" yes
  BASE_V2=$((BASE_V2 + 1))   # the ledger now holds one more v2 contract for the next branch
}

banner "(a) row delete on the snapshot, then restart PQS"
q pqs_a "delete from __contracts c using __packages p where p.pk = c.package_pk and p.id = '$V1' and c.archived_at_ix is null" \
  > "$D_DIR/a-delete.txt" 2>&1; res a deleteRc "$?"
res a deleteOutput "$(tr '\n' ' ' < "$D_DIR/a-delete.txt")"
pqs_start pqs_a Oldest
wait_for 60 "a-resumes" active_eq pqs_a "$V2" "$BASE_V2"
branch_post a pqs_a
pqs_stop

banner "(c) prune archived history (the existing M3 approach) on the snapshot"
pqs_start pqs_c Oldest
wait_for 60 "c-resumes" active_eq pqs_c "$V2" "$BASE_V2"
# a prune cannot target PQS's latest checkpoint, so branch_post's extra tx comes first
BASE_V2_C=$BASE_V2; branch_post c pqs_c
res c v1HistoryBeforePrune "$(history_pkg pqs_c "$V1")"
q pqs_c "select * from prune_archived_to_offset_dry_run($BASE_CKPT)" > "$D_DIR/c-dry.txt" 2>&1; res c dryRunRc "$?"
q pqs_c "select * from prune_archived_to_offset($BASE_CKPT)" > "$D_DIR/c-prune.txt" 2>&1; res c pruneRc "$?"
chk c v1HistoryAfterPrune "$(history_pkg pqs_c "$V1")" 0
chk c v2ActiveAfterPrune "$(active_pkg pqs_c "$V2")" "$BASE_V2"
chk c pqsAliveAfterPrune "$(pqs_alive && echo yes || echo no)" yes
rcon "tx-c2" console/pqsp-tx.canton >/dev/null || rc=1
off="$(sed -n 's/^T OFFSET=//p' "$D_DIR/$RNAME.out")"; wait_for 60 "c-ingests-after-prune" ckpt_ge pqs_c "$off"
chk c ingestsAfterPrune "$(ckpt_ge pqs_c "$off" && echo yes || echo no)" yes
BASE_V2=$((BASE_V2 + 1))
pqs_stop

banner "(b1) fresh re-ingest from Oldest"
q postgres "create database pqs_b1" >/dev/null
pqs_start pqs_b1 Oldest
wait_for 120 "b1-catches-up" active_eq pqs_b1 "$V2" "$BASE_V2"
branch_post b1 pqs_b1
pqs_stop

banner "(b2) fresh start from Latest (ACS)"
q postgres "create database pqs_b2" >/dev/null
pqs_start pqs_b2 Latest
wait_for 120 "b2-seeds" active_eq pqs_b2 "$V2" "$BASE_V2"
branch_post b2 pqs_b2
pqs_stop

mn_daemon_stop
echo; echo "#### PQS-P results"; column -t -s$'\t' "$RES"
echo "PQS-P rc=$rc"
exit $rc
