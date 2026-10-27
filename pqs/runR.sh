#!/usr/bin/env bash
# FRED reset with PQS attached. CASE=live (PQS left running), restart (PQS restarted on its old
# database), fresh (database dropped and recreated), late (PQS restarted on its old database
# only after L2 has passed K1). L1 is padded so PQS's checkpoint K1 is well
# ahead of L2's start; L2 is then observed below K1 and after a real transaction passes K1.
# Every Items contract is in a manifest with its own offset and expected state, and PQS is
# compared to it by contract id.
CASE=${CASE:?CASE=live|restart|fresh|late}; RUN=R-$CASE; . "$(dirname "$0")/lib.sh"
DB=rdb_$CASE; I="items:Items:Item"
ITEMS_DAR=$FIX/items-v1.dar
manifest() { grep '^T C=' "$LAST_LOG" | sed 's/^T C=//' | tr ',' '\t' | sed "s/^/$1	/" >> "$LOGDIR/manifest-$1.tsv"; }
strip() { perl -pe 's/\e\[[0-9;]*m//g' "$PQS_LOG"; }
events() { strip | grep -E '^[0-9:.]+ [WEF] |WARN|ERROR|Exception' | grep -v '^\[diagnostics\]' | cut -c1-400 > "$LOGDIR/pqs-events-$1.txt"; measure "$1" pqs_event_lines "$(grep -c . "$LOGDIR/pqs-events-$1.txt")"; }
checkpoint() { _sql "$DB" "select (latest_checkpoint()).offset" 2>/dev/null | tail -1; }
# sqlo <name> <db> <sql> : logged like sql, but an outcome, never fatal.
sqlo() { nextlog "$1"; _sql "$2" "$3" > "$LOG" 2>&1; local rc=$?
  printf '%s\t%s\twant=outcome\tgot=rc%s\t-\t-\t%s\n' "$N" "$1" "$rc" "$(basename "$LOG")" >> "$LOGDIR/steps.tsv"; LAST_LOG="$LOG"; return $rc; }

pqs_state() {  # tag
  local tag="$1"
  measure "$tag" pqs_alive "$(pqs_alive && echo yes || echo no)"
  pqs_alive || measure "$tag" pqs_fatal_cause "$(pqs_crash_cause)"
  local cp; cp=$(checkpoint); measure "$tag" checkpoint "${cp:-none}"
  con "$tag-ledger-state" ok c-state.canton; local e; e=$(tval END); local nsl; nsl=$(tval NSLIST)
  measure "$tag" ledger_end "$e"; measure "$tag" ledger_namespaces "$nsl"
  sqlo "$tag-pqs-rows" "$DB" "select contract_id, case when archived_at_offset is null then 'active' else 'archived' end, array_to_string(signatories, ',') from creates('$I') order by 1"
  grep -v '^NOTICE' "$LAST_LOG" | grep ' | ' > "$LOGDIR/pqs-$tag.tsv"
  local mans=("$LOGDIR/manifest-L1.tsv"); [ -s "$LOGDIR/manifest-L2.tsv" ] && mans+=("$LOGDIR/manifest-L2.tsv")
  python3 -I "$AB/compare.py" "$LOGDIR" "$tag" "$LOGDIR/pqs-$tag.tsv" "${mans[@]}" > "$LOGDIR/compare-$tag.txt"
  while IFS='=' read -r k v; do measure "$tag" "$k" "$v"; done < "$LOGDIR/compare-$tag.txt"
  local n1rows n2rows; n1rows=$(grep -c "::$N1" "$LOGDIR/pqs-$tag.tsv"); n2rows=0; [ -n "${N2:-}" ] && n2rows=$(grep -c "::$N2" "$LOGDIR/pqs-$tag.tsv")
  measure "$tag" ns_N1_rows "$n1rows"; measure "$tag" ns_N2_rows "$n2rows"
  measure "$tag" signal_a_checkpoint_gt_end "$([ -n "$cp" ] && [ "$cp" -gt "$e" ] 2>/dev/null && echo FIRES || echo no)"
  measure "$tag" signal_b_unknown_party_rows "$([ "$n1rows" -gt 0 ] && ! echo ",$nsl," | grep -q ",$N1," && echo FIRES || echo no)"
  events "$tag"
}
observe() {  # tag seconds : fixed elapsed-time window; never returns early on a high checkpoint
  local tag="$1" secs="$2" f="$LOGDIR/observe-$1.tsv" t0; t0=$(now)
  con "$tag-observe-start" ok c-state.canton; measure "$tag" window_start_ledger_end "$(tval END)"
  printf 't\talive\tcheckpoint\tlog_lines\twarn_err_fatal\n' > "$f"
  while :; do
    local el; el=$(python3 -c "print(int($(now)-$t0))")
    printf '%s\t%s\t%s\t%s\t%s\n' "$el" "$(pqs_alive && echo yes || echo no)" "$(checkpoint)" \
      "$(wc -l < "$PQS_LOG" | tr -d ' ')" "$(strip | grep -cE '^[0-9:.]+ [WEF] ')" >> "$f"
    [ "$el" -ge "$secs" ] && break; sleep 5
  done
  con "$tag-observe-end" ok c-state.canton; measure "$tag" window_end_ledger_end "$(tval END)"
}

# ---- L1, padded ----
sandbox_start
ITEMS_DAR=$ITEMS_DAR G1_DAR=$FIX/A-g1.dar con l1-init ok c-init-r.canton; manifest L1
ITEMS=$(tval ITEMS); N1=$(tval NS); measure L1 namespace "$N1"
createdb_fresh $DB; pqs_start $DB
ITEMS=$ITEMS LABEL=L1 COUNT=30 con l1-pump ok c-pump.canton; manifest L1; wait_pqs_offset $DB "$(tval LASTTX)"
K1=$(checkpoint); offset K1 "$K1"; con l1-end ok c-state.canton; offset E1 "$(tval END)"
pqs_state L1
[ "$(grep '^L1	L1_missing	' "$LOGDIR/measures.tsv" | cut -f3)" = 0 ] && [ "$(grep '^L1	L1_wrongstate	' "$LOGDIR/measures.tsv" | cut -f3)" = 0 ] \
  || die "L1 not fully ingested before the reset"

# ---- the reset ----
case $CASE in
  live)    sandbox_stop; sandbox_start ;;
  restart) pqs_stop; sandbox_stop; sandbox_start; pqs_start $DB ;;
  late)    pqs_stop; sandbox_stop; sandbox_start ;;  # PQS restarted on the old database only after L2 passes K1
  fresh)   pqs_stop; sandbox_stop; sandbox_start
           t0=$(now); createdb_fresh $DB; measure fresh db_recreate_seconds "$(python3 -c "print(round($(now)-$t0,3))")"
           T_PQS=$(now); pqs_start $DB ;;
esac
measure reset pqs_alive_after_reset "$(pqs_alive && echo yes || echo no)"

# ---- L2 below K1 ----
ITEMS_DAR=$ITEMS_DAR G1_DAR=$FIX/A-g1.dar con l2-init ok c-init-r.canton; manifest L2; T_INIT=$(now)
N2=$(tval NS); L2TX=$(tval LASTTX); L2END=$(tval END); [ "$(tval ITEMS)" = "$ITEMS" ] || die "items id differs on L2"
measure L2 namespace "$N2"; offset L2_init_lasttx "$L2TX"; offset L2_init_end "$L2END"
if [ "$CASE" = fresh ]; then  # PQS start -> L2 init contracts fully correct, by manifest comparison
  ok=no; for _ in $(seq 1 120); do
    _sql $DB "select contract_id, case when archived_at_offset is null then 'active' else 'archived' end, '' from creates('$I')" 2>/dev/null > "$LOGDIR/.probe.tsv"
    python3 -I "$AB/compare.py" "$LOGDIR" probe "$LOGDIR/.probe.tsv" "$LOGDIR/manifest-L1.tsv" "$LOGDIR/manifest-L2.tsv" > "$LOGDIR/.probe.txt"
    grep -q '^L2_missing=0$' "$LOGDIR/.probe.txt" && grep -q '^L2_wrongstate=0$' "$LOGDIR/.probe.txt" && grep -q '^L1_present=0$' "$LOGDIR/.probe.txt" && { ok=yes; break; }
    sleep 1
  done
  measure fresh l2_init_correct "$ok"
  measure fresh seconds_pqs_start_to_correct "$(python3 -c "print(round($(now)-$T_PQS,1))")"
  measure fresh seconds_init_done_to_correct "$(python3 -c "print(round($(now)-$T_INIT,1))")"
  rm -f "$LOGDIR"/*-probe.txt
fi
con l2-below-state ok c-state.canton; L2END2=$(tval END); offset L2_end_before_window "$L2END2"
if [ "$N2" != "$N1" ] && [ "$L2TX" -lt "$K1" ] && [ "$L2END" -lt "$K1" ] && [ "$L2END2" -lt "$K1" ]; then measure below exercised yes
else measure below exercised "NOT EXERCISED (N1=$N1 N2=$N2 lasttx=$L2TX end=$L2END/$L2END2 K1=$K1)"; fi
observe below 30; pqs_state below

# ---- L2 past K1 (a real submitted transaction beyond K1 + 5) ----
from=1; LT=$L2TX
while [ "$LT" -le $((K1 + 5)) ] && [ "$from" -le 200 ]; do
  ITEMS=$ITEMS LABEL=L2 COUNT=10 FROM=$from con "l2-pump-$from" ok c-pump.canton; manifest L2
  LT=$(tval LASTTX); from=$((from + 10))
done
offset L2_pump_lasttx "$LT"; measure past pumped "$((from - 1))"
if [ "$LT" -gt $((K1 + 5)) ]; then measure past exercised yes; else measure past exercised "NOT EXERCISED (cap reached, lasttx=$LT K1=$K1)"; fi
[ "$CASE" = late ] && pqs_start $DB
observe past 60; pqs_state past
pqs_stop; sandbox_stop
echo "RUN R-$CASE COMPLETE"
