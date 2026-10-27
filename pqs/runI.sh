#!/usr/bin/env bash
# Interfaces: template Things:Thing (package things, g1 Text -> g2 Int, both 1.0.0) implements
# LabelledApi:Labelled from a separate, never-reloaded iface-api package. Does Option A's prune also
# clean the retired generation's rows in the INTERFACE view?
RUN=${RUN_NAME:-I}; . "$(dirname "$0")/lib.sh"
G1=$(awk -F'\t' '$1=="T-g1"{print $4}' "$FIX/fixtures.tsv"); G2=$(awk -F'\t' '$1=="T-g2"{print $4}' "$FIX/fixtures.tsv")
DB=idb; T="things:Things:Thing"; L="iface-api:LabelledApi:Labelled"; export MOD=Things ENT=Thing
measure_i() {  # tag
  mv_ "$1" template_retired  "$1-t-retired"  $DB "select count(*) from creates('$T') where package_id <> '$G2'"
  mv_ "$1" template_current  "$1-t-current"  $DB "select count(*) from active('$T')"
  mv_ "$1" iface_active      "$1-i-active"   $DB "select count(*) from active('$L')"
  mv_ "$1" iface_creates     "$1-i-creates"  $DB "select count(*) from creates('$L')"
}
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/T-g1.dar con init ok c-init.canton
TX=$(tval LASTTX); [ "$(tval G1)" = "$G1" ] || die "g1 id mismatch"
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX"
measure pqs filter_log "$(grep -oE 'Contract filter inclusive of [0-9]+ templates and [0-9]+ interfaces' "$PQS_LOG" | tail -1)"
PKG=$G1 TY=Text con g1-create ok c-create.canton; wait_pqs_offset $DB "$(tval LASTTX)"
measure_i g1
PKG=$G1 con g2-archive ok c-archive.canton; OA=$(tval END); offset O_after_1 "$OA"
OLD=$G1 NEW_DAR=$FIX/T-g2.dar con g2-swap ok c-swap.canton
PKG=$G2 TY=Int con g2-create ok c-create.canton; wait_pqs_offset $DB "$(tval LASTTX)"
measure_i before-prune
sql prune ok $DB "select * from prune_archived_to_offset($OA)"
measure_i after-prune
measure pqs filter_log_end "$(grep -oE 'Contract filter inclusive of [0-9]+ templates and [0-9]+ interfaces' "$PQS_LOG" | tail -1)"
pqs_alive && measure pqs running_after yes || measure pqs running_after no
pqs_stop; sandbox_stop
echo "RUN I COMPLETE"
