#!/usr/bin/env bash
# PQS on a participant connected to two synchronizers (`dpm sandbox --multi-sync`).
# One reload (g1 Text -> g2 Int, same name and version), Option A clean-up, PQS running throughout:
#   M-move     what PQS shows for a contract moved A->B (completed) and one left mid-move
#   M-prune    archive on both, swap on each synchronizer, prune to O_after: what is left
#   M-recover  fresh re-ingest of the whole two-synchronizer history, then one prune
# PARTY_FILTER=<filter> restricts PQS to those parties (--pipeline-filter-parties), as QuickStart's
# single-party PQS users are, and adds: Bob (not in the filter) with a contract PQS must not show;
# Carol allocated while PQS runs; a restart with Carol added to the filter, on the same database.
RUN=${RUN_NAME:-M}; . "$(dirname "$0")/lib.sh"
G1=$(awk -F'\t' '$1=="A-g1"{print $4}' "$FIX/fixtures.tsv"); G2=$(awk -F'\t' '$1=="A-g2"{print $4}' "$FIX/fixtures.tsv")
PF=(); [ -n "${PARTY_FILTER:-}" ] && PF=(--pipeline-filter-parties "$PARTY_FILTER")
DB=mdb; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
cms() { local name="$1" kv; shift; for kv in "$@"; do export "$kv"; done; con "$name" ok c-ms.canton; }
row() {  # tag db cid label : is the contract in active() / creates(), from PQS's view
  mv_ "$1" "$4_active"  "$1-$4-active"  "$2" "select count(*) from active('$M') where contract_id = '$3'"
  mv_ "$1" "$4_creates" "$1-$4-creates" "$2" "select count(*) from creates('$M') where contract_id = '$3'"
}
counts() {  # tag db
  mv_ "$1" retired_creates "$1-retired" "$2" "select count(*) from creates('$M') where package_id <> '$G2'"
  mv_ "$1" retired_active  "$1-retired-active" "$2" "select count(*) from active('$M') where package_id <> '$G2'"
  mv_ "$1" current_rows    "$1-current" "$2" "select count(*) from active('$M') where package_id = '$G2'"
  mv_ "$1" anchor          "$1-anchor"  "$2" "select count(*) from active('$I') where contract_id = '$ANCHOR'"
  mv_ "$1" collateral      "$1-collateral" "$2" "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"
}
checkpoint() { mv_ "$1" latest_checkpoint "$1-latest" "$2" "select (latest_checkpoint()).offset"; }

# The multi-sync sandbox instead of the plain one.
sandbox_start_ms() {
  nextlog sandbox-multisync; local log="$LOG"
  pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 3
  nohup dpm sandbox --multi-sync --no-tty > "$log" 2>&1 < /dev/null &
  for _ in $(seq 1 90); do grep -q "Canton sandbox is ready" "$log" && break; sleep 2; done
  grep -q "Canton sandbox is ready" "$log" || die "multi-sync sandbox failed, see $log"
  printf '%s\tsandbox-multisync\twant=ok\tgot=ok\t-\t-\t%s\n' "$N" "$(basename "$log")" >> "$LOGDIR/steps.tsv"
}

sandbox_start_ms
cms init PHASE=init ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar
[ "$(tval G1)" = "$G1" ] || die "g1 id $(tval G1) != fixture $G1"
ITEMS=$(tval ITEMS); ANCHOR=$(tval ANCHOR); COLLATERAL=$(tval COLLATERAL)
M1=$(tval M1); M2=$(tval M2); M3=$(tval M3); M4=$(tval M4); LASTTX=$(tval LASTTX)
if [ -n "${PARTY_FILTER:-}" ]; then
  cms bob PHASE=other-party NAME=Bob BOTH=0 ITEMS=$ITEMS; BOB_ITEM=$(tval OTHER_ITEM)
fi
createdb_fresh $DB; pqs_start $DB ${PF[@]+"${PF[@]}"}; wait_pqs_offset $DB "$LASTTX"
measure pqs on_behalf_of "$(grep -m1 -oE "on behalf of '[^']*'" "$PQS_LOG" | sed -E 's/::[0-9a-f]{8}[0-9a-f]*/::…/g')"
visible() { mv_ "$1" "$2_item_visible" "$1-$2" "$3" "select count(*) from creates('$I') where contract_id = '$4'"; }
[ -n "${PARTY_FILTER:-}" ] && visible init bob $DB "$BOB_ITEM"
measure pqs synchronizer_columns "$(_sql $DB "select string_agg(column_name, ',') from information_schema.columns where table_name='__contracts' and column_name ilike '%sync%'" 2>&1 | tail -1)"
counts init $DB

# ---- M-move -----------------------------------------------------------------------------------
cms reassign PHASE=reassign M3=$M3 M4=$M4; U4=$(tval U4); END_R=$(tval END)
measure move m3_on "$(tval M3_ON)"; measure move m4_in_flight "$(tval M4_INFLIGHT)"
sleep 5; checkpoint move-no-marker $DB; measure move ledger_end "$END_R"
cms marker1 PHASE=marker ITEMS=$ITEMS LABEL=marker1; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
for c in m1:$M1 m2:$M2 m3:$M3 m4:$M4; do row move $DB "${c#*:}" "${c%%:*}"; done
cms complete PHASE=complete U4=$U4; measure move m4_on_after_complete "$(tval M4_ON)"
cms marker2 PHASE=marker ITEMS=$ITEMS LABEL=marker2; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
row move-completed $DB "$M4" m4
if [ -n "${PARTY_FILTER:-}" ]; then
  cms carol PHASE=other-party NAME=Carol BOTH=1 ITEMS=$ITEMS; CAROL_ITEM=$(tval OTHER_ITEM)
  cms marker-carol PHASE=marker ITEMS=$ITEMS LABEL=marker-carol; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
  visible carol-running carol $DB "$CAROL_ITEM"
fi

# ---- M-prune ------------------------------------------------------------------------------------
cms archive-g1 PHASE=archive PKG=$G1; OA=$(tval END); offset O_after_1 "$OA"; measure prune archived_on "$(tval ARCHIVED_ON)"
cms swap PHASE=swap OLD=$G1 NEW_DAR=$FIX/A-g2.dar TY=Int; [ "$(tval NEW)" = "$G2" ] || die "g2 id mismatch"
LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
counts before-prune $DB
for c in m1:$M1 m2:$M2 m3:$M3 m4:$M4; do row before-prune $DB "${c#*:}" "${c%%:*}"; done
t0=$(now)
sql prune-dry ok $DB "select * from prune_archived_to_offset_dry_run($OA)"
sql prune     ok $DB "select * from prune_archived_to_offset($OA)"
measure prune cleanup_seconds "$(python3 -c "print(round($(now)-$t0,3))")"
pqs_alive || die "PQS not running after prune"; measure prune pqs_running_through_cleanup yes
counts after-prune $DB
for c in m1:$M1 m2:$M2 m3:$M3 m4:$M4; do row after-prune $DB "${c#*:}" "${c%%:*}"; done
cms marker3 PHASE=marker ITEMS=$ITEMS LABEL=marker3; LASTTX=$(tval LASTTX)
try_wait_pqs_offset $DB "$LASTTX" 60; measure prune pqs_after_prune "$WAIT_RESULT"
pqs_stop
if [ -n "${PARTY_FILTER:-}" ]; then
  # Restart on the SAME database with Carol added: does her earlier contract appear (backfill)?
  pqs_start $DB --pipeline-filter-parties "$PARTY_FILTER | Carol::*"
  cms marker4 PHASE=marker ITEMS=$ITEMS LABEL=marker4; LASTTX=$(tval LASTTX)
  try_wait_pqs_offset $DB "$LASTTX" 60; measure widen restart "$WAIT_RESULT"
  measure widen on_behalf_of "$(grep -m1 -oE "on behalf of '[^']*'" "$PQS_LOG" | sed -E 's/::[0-9a-f]{8}[0-9a-f]*/::…/g')"
  [ "$WAIT_RESULT" = caught-up ] && visible widen-same-db carol $DB "$CAROL_ITEM"
  [ "$WAIT_RESULT" = pqs-crashed ] && measure widen crash_cause "$(pqs_crash_cause)"
  pqs_stop
fi

# ---- M-recover ---------------------------------------------------------------------------------
createdb_fresh mdb_recover; pqs_start mdb_recover ${PF[@]+"${PF[@]}"}
try_wait_pqs_offset mdb_recover "$LASTTX" 120; measure recover ingest "$WAIT_RESULT"
[ "$WAIT_RESULT" = pqs-crashed ] && measure recover crash_cause "$(pqs_crash_cause)"
if [ "$WAIT_RESULT" = caught-up ]; then
  counts recover-before-prune mdb_recover
  [ -n "${PARTY_FILTER:-}" ] && visible recover bob mdb_recover "$BOB_ITEM" && visible recover carol mdb_recover "$CAROL_ITEM"
  sql recover-prune ok mdb_recover "select * from prune_archived_to_offset($OA)"
  counts recover-after-prune mdb_recover
fi
pqs_stop
sandbox_stop
echo "RUN M COMPLETE"
