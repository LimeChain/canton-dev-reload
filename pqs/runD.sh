#!/usr/bin/env bash
# Old DAR removal vs a fresh PQS re-ingest. One breaking reload (g1 Text -> g2 Int), then two fresh
# PQS databases over the same ledger: D-keep re-ingests with the old DAR still on the participant
# (the control), D-removed re-ingests after the old DAR is removed. The participant still serves the
# old events either way; the question is whether PQS can ingest them without the package.
RUN=${RUN_NAME:-D}; . "$(dirname "$0")/lib.sh"
ID=(_); for n in 1 2; do ID+=("$(awk -F'\t' -v k="A-g$n" '$1==k{print $4}' "$FIX/fixtures.tsv")"); done
M="mirrors:Mirrors:Mirror"
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar con init ok c-init.canton
PKG=${ID[1]} TY=Text con g1-create ok c-create.canton
PKG=${ID[1]} con g1-archive ok c-archive.canton
OLD=${ID[1]} NEW_DAR=$FIX/A-g2.dar con swap ok c-swap.canton
PKG=${ID[2]} TY=Int con g2-create ok c-create.canton; TX=$(tval LASTTX); offset last_tx "$TX"

reingest() {  # tag db
  createdb_fresh "$2"; pqs_start "$2"; try_wait_pqs_offset "$2" "$TX" 60
  measure "$1" wait_result "$WAIT_RESULT"
  measure "$1" pqs_alive "$(pqs_alive && echo yes || echo no)"
  measure "$1" checkpoint "$(_sql "$2" "select (latest_checkpoint()).offset" 2>/dev/null | tail -1)"
  measure "$1" g1_creates "$(_sql "$2" "select count(*) from creates('$M') where package_id = '${ID[1]}'" 2>/dev/null | tail -1)"
  measure "$1" g2_active "$(_sql "$2" "select count(*) from active('$M') where package_id = '${ID[2]}'" 2>/dev/null | tail -1)"
  measure "$1" no_package_lines "$(grep -c 'No package' "$PQS_LOG")"
  measure "$1" crash_cause "$(pqs_crash_cause)"
  pqs_stop
}
reingest keep ddb_keep
OLD=${ID[1]} con remove-g1 ok c-remove.canton
reingest removed ddb_removed

R() { awk -F'\t' -v t="$1" -v k="$2" '$1==t && $2==k{print $3}' "$LOGDIR/measures.tsv"; }
assert_eq() { [ "$2" = "$3" ] && measure assert "$1" "ok ($2)" || die "assert $1: got '$2', want '$3'"; }
assert_eq keep_caught_up     "$(R keep wait_result)" caught-up
assert_eq keep_g1_history    "$(R keep g1_creates)" 2
assert_eq keep_g2_active     "$(R keep g2_active)" 2
# After the removal PQS cannot finish the re-ingest: report whether it timed out or crashed, and
# require that it did not catch up and holds no g2 rows.
[ "$(R removed wait_result)" != caught-up ] && measure assert removed_not_caught_up "ok ($(R removed wait_result))" \
  || die "assert removed_not_caught_up: PQS caught up without the old DAR"
assert_eq removed_g2_active  "$(v=$(R removed g2_active); echo "${v:-0}")" 0
sandbox_stop
echo "RUN D COMPLETE"
