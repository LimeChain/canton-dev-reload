#!/usr/bin/env bash
# The reviewer's Option A claims, literally: prune target vs latest checkpoint (L1), repeat prunes
# (L2), restarting PQS with the version filter after the prune (L3) and one more reload under it
# (L3b). VARIANT=filter|nofilter differ only in the filter given at the L3 restart.
VARIANT=${VARIANT:?filter|nofilter}; RUN=L-$VARIANT; . "$(dirname "$0")/lib.sh"
case $VARIANT in filter) RESTART_FILTER='(* & !mirrors:*) | mirrors@>=1.0.1' ;; nofilter) RESTART_FILTER='*' ;; esac
fx() { awk -F'\t' -v k="$1" '$1==k{print $4}' "$FIX/fixtures.tsv"; }
G1=$(fx B-g1); G2=$(fx B-g2); G3=$(fx B-g3)
DB=ldb_$VARIANT; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
sqlo() { nextlog "$1"; _sql "$2" "$3" > "$LOG" 2>&1; local rc=$?
  printf '%s\t%s\twant=outcome\tgot=rc%s\t-\t-\t%s\n' "$N" "$1" "$rc" "$(basename "$LOG")" >> "$LOGDIR/steps.tsv"; LAST_LOG="$LOG"; return $rc; }
msg() { grep -m1 -oE '(ERROR|WARNING|NOTICE):.*' "$LAST_LOG" | cut -c1-160; }
ids_of() { grep '^T C=' "$LAST_LOG" | sed 's/^T C=//; s/,.*//'; }
probe() {  # tag target : dry run then real prune, both outcomes
  sqlo "$1-dry" $DB "select * from prune_archived_to_offset_dry_run($2)"; local rc=$?
  measure "$1" "dry_run_target_$2" "rc=$rc $(msg) | $(grep -v -E '^(ERROR|WARNING|NOTICE|DETAIL|CONTEXT|HINT|PL/pgSQL|SQL)' "$LAST_LOG" | tail -1)"
  sqlo "$1-prune" $DB "select * from prune_archived_to_offset($2)"; rc=$?
  measure "$1" "prune_target_$2" "rc=$rc $(msg) | $(grep -v -E '^(ERROR|WARNING|NOTICE|DETAIL|CONTEXT|HINT|PL/pgSQL|SQL)' "$LAST_LOG" | tail -1)"
  mv_ "$1" pruned_offset "$1-pruned" $DB "select coalesce(pruned_offset()::text,'null')"
  mv_ "$1" retired_g1_creates "$1-retired" $DB "select count(*) from creates('$M') where package_id = '$G1'"
  mv_ "$1" g1_ids_present "$1-g1ids" $DB "select coalesce(string_agg(left(contract_id,12)||'@'||coalesce(archived_at_offset::text,'active'), ',' order by contract_id),'-') from creates('$M') where package_id = '$G1'"
}
present() {  # tag name ids...
  local tag=$1 name=$2; shift 2; local list; list=$(printf "'%s'," "$@"); list=${list%,}
  mv_ "$tag" "$name" "$tag-$name" $DB "select count(*) || ' of $#' from creates() where contract_id in ($list)"
}
pqs_events() { perl -pe 's/\e\[[0-9;]*m//g' "$PQS_LOG" | grep -E '^[0-9:.]+ [WEF] |WARN|ERROR|Exception|Contract filter|Initialised [0-9]+ packages' | grep -v '^\[diagnostics\]' | cut -c1-300 > "$LOGDIR/pqs-events-$1.txt"; }

# ---- 1. setup (fatal) ----
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/B-g1.dar con init ok c-init.canton
ITEMS=$(tval ITEMS); ANCHOR=$(tval ANCHOR); TX0=$(tval LASTTX); [ "$(tval G1)" = "$G1" ] || die "g1 id"
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX0"
PKG=$G1 TY=Text COUNT=2 con g1-add ok c-add.canton; G1_IDS=$(ids_of | paste -sd' ' -); measure ids g1 "$G1_IDS"; wait_pqs_offset $DB "$(tval LASTTX)"

# ---- 2. L1: prune target vs the latest checkpoint ----
PKG=$G1 con g1-archive ok c-archive.canton; X=$(tval LASTTX); offset X "$X"
wait_pqs_offset $DB "$X"
C=$(_sql $DB "select (latest_checkpoint()).offset" | tail -1); offset C "$C"
con end-1 ok c-end.canton; E=$(tval END); offset E "$E"
measure L1 checkpoint_equals_archive_offset "$([ "$C" = "$X" ] && echo yes || echo "no (C=$C X=$X)")"
probe L1-i "$C"
if [ "$E" -gt "$C" ]; then probe L1-ii "$E"; else measure L1-ii skipped "ledger end $E not above checkpoint $C"; fi
probe L1-iii "$((C - 1))"
OLD=$G1 NEW_DAR=$FIX/B-g2.dar con swap-g2 ok c-swap.canton; [ "$(tval NEW)" = "$G2" ] || die "g2 id"
PKG=$G2 TY=Int COUNT=2 con g2-add ok c-add.canton; G2_IDS=$(ids_of | paste -sd' ' -); measure ids g2_seed "$G2_IDS"; wait_pqs_offset $DB "$(tval LASTTX)"
probe L1-iv "$X"

# ---- 3. L2: repeat prunes ----
mv_ L2 rows_before L2-rows-before $DB "select (select count(*) from __contracts)||'/'||(select count(*) from __events)||'/'||(select count(*) from __transactions)"
probe L2-same "$X"
probe L2-lower "$((X - 1))"
mv_ L2 rows_after L2-rows-after $DB "select (select count(*) from __contracts)||'/'||(select count(*) from __events)||'/'||(select count(*) from __transactions)"

# ---- 4. L3: restart PQS on the same database with RESTART_FILTER (observational from here) ----
L3_OK=no
if [ "$(grep '^L1-iv	retired_g1_creates' "$LOGDIR/measures.tsv" | cut -f3)" != 0 ]; then
  measure L3 status "precondition not met: retired g1 rows after (iv) not 0"
else
  measure L3 restart_filter "$RESTART_FILTER"
  pqs_stop; PQS_FILTER="$RESTART_FILTER" pqs_start $DB; sleep 8
  measure L3 pqs_alive_after_restart "$(pqs_alive && echo yes || echo "no: $(pqs_crash_cause)")"
  measure L3 filter_line "$(perl -pe 's/\e\[[0-9;]*m//g' "$PQS_LOG" | grep -oE 'Contract filter[^ ]* inclusive of [0-9]+ templates and [0-9]+ interfaces' | tail -1)"
  measure L3 pipeline_filter_config "$(perl -pe 's/\e\[[0-9;]*m//g' "$PQS_LOG" | grep -m1 -oE 'contracts="[^"]*"')"
  PKG=$G2 TY=Int COUNT=2 FROM=3 con l3-g2-add ok c-add.canton; L3_G2=$(ids_of | paste -sd' ' -); T1=$(tval LASTTX)
  ITEMS=$ITEMS LABEL=L3 COUNT=1 con l3-item ok c-pump.canton; L3_ITEM=$(ids_of); T2=$(tval LASTTX)
  measure ids l3 "$L3_G2 $L3_ITEM"
  try_wait_pqs_offset $DB "$T2" 90; measure L3 catch_up "$WAIT_RESULT"
  pqs_events L3
  if [ "$WAIT_RESULT" = caught-up ]; then
    present L3 new_g2_present $L3_G2; present L3 new_item_present $L3_ITEM
    mv_ L3 g2_active L3-g2 $DB "select count(*) from active('$M') where package_id = '$G2'"
    mv_ L3 anchor L3-anchor $DB "select count(*) from active('$I') where contract_id = '$ANCHOR'"
    mv_ L3 retired_g1 L3-retired $DB "select count(*) from creates('$M') where package_id = '$G1'"
    L3_OK=yes
  else measure L3 status "not reached: PQS $WAIT_RESULT ($(pqs_crash_cause))"; fi
fi

# ---- 5. L3b: the next reload under the same filter ----
if [ "$L3_OK" = yes ]; then
  PKG=$G2 con g2-archive ok c-archive.canton; X2=$(tval LASTTX); offset X2 "$X2"
  OLD=$G2 NEW_DAR=$FIX/B-g3.dar con swap-g3 ok c-swap.canton; [ "$(tval NEW)" = "$G3" ] || die "g3 id"
  PKG=$G3 TY=Bool COUNT=2 con g3-add ok c-add.canton; G3_IDS=$(ids_of | paste -sd' ' -); measure ids g3 "$G3_IDS"
  try_wait_pqs_offset $DB "$(tval LASTTX)" 90; measure L3b catch_up "$WAIT_RESULT"
  pqs_events L3b
  measure L3b initialised_packages "$(perl -pe 's/\e\[[0-9;]*m//g' "$PQS_LOG" | grep -oE 'Initialised [0-9]+ packages' | awk '{print $2}' | paste -sd, -)"
  if [ "$WAIT_RESULT" = caught-up ]; then
    present L3b g3_present $G3_IDS
    sqlo L3b-prune $DB "select * from prune_archived_to_offset($X2)"; measure L3b prune "rc=$? $(msg) | $(grep '|' "$LAST_LOG" | tail -1)"
    mv_ L3b g3_active L3b-g3 $DB "select count(*) from active('$M') where package_id = '$G3'"
    mv_ L3b retired_non_g3 L3b-retired $DB "select count(*) from creates('$M') where package_id <> '$G3'"
    mv_ L3b anchor L3b-anchor $DB "select count(*) from active('$I') where contract_id = '$ANCHOR'"
    mv_ L3b items_total L3b-items $DB "select count(*) from active('$I')"
  else measure L3b status "not reached: PQS $WAIT_RESULT ($(pqs_crash_cause))"; fi
  measure L3b pqs_alive_end "$(pqs_alive && echo yes || echo no)"
else
  measure L3b status "not reached (L3 did not complete)"
fi
pqs_stop; sandbox_stop
echo "RUN L-$VARIANT COMPLETE"
