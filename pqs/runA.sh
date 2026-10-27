#!/usr/bin/env bash
# Option A: prune archived history after each reload. Four generations (g1..g4), all mirrors 1.0.0,
# so three reloads. PQS keeps running throughout. Then A-recover (fresh re-ingest + one prune) and
# A-cli (the CLI prune with its own --postgres-* flags).
RUN=${RUN_NAME:-A}; . "$(dirname "$0")/lib.sh"
TYPES=(_ Text Int Bool Decimal)
ID=(_); for n in 1 2 3 4; do ID+=("$(awk -F'\t' -v k="A-g$n" '$1==k{print $4}' "$FIX/fixtures.tsv")"); done
DB=adb; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"

measure_all() {  # tag gen db
  local tag="$1" n="$2" db="$3" cur="${ID[$2]}"
  mv_ "$tag" retired_active "$tag-retired-active" "$db" "select count(*) from active('$M') where package_id <> '$cur'"
  mv_ "$tag" retired_creates "$tag-retired-creates" "$db" "select count(*) from creates('$M') where package_id <> '$cur'"
  mv_ "$tag" current_rows "$tag-current" "$db" "select count(*) from active('$M') where package_id = '$cur'"
  mv_ "$tag" anchor "$tag-anchor" "$db" "select count(*) from active('$I') where contract_id = '$ANCHOR'"
  mv_ "$tag" collateral "$tag-collateral" "$db" "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"
}

sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar con init ok c-init.canton
ANCHOR=$(tval ANCHOR); COLLATERAL=$(tval COLLATERAL); TX=$(tval LASTTX)
[ "$(tval G1)" = "${ID[1]}" ] || die "uploaded g1 id $(tval G1) != fixture ${ID[1]}"
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX"

con g1-before ok c-end.canton; offset O_before_1 "$(tval END)"
PKG=${ID[1]} TY=Text con g1-create ok c-create.canton; wait_pqs_offset $DB "$(tval LASTTX)"
measure_all g1 1 $DB

for n in 2 3 4; do
  p=$((n-1))
  PKG=${ID[$p]} con "g$n-archive-g$p" ok c-archive.canton; offset "O_after_$p" "$(tval END)"; OA=$(tval END)
  OLD=${ID[$p]} NEW_DAR=$FIX/A-g$n.dar con "g$n-swap" ok c-swap.canton
  [ "$(tval NEW)" = "${ID[$n]}" ] || die "swapped-in id $(tval NEW) != fixture ${ID[$n]}"
  con "g$n-before" ok c-end.canton; offset "O_before_$n" "$(tval END)"
  PKG=${ID[$n]} TY=${TYPES[$n]} con "g$n-create" ok c-create.canton; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
  measure_all "g$n-before-cleanup" $n $DB
  # ---- Option A clean-up: dry run, then prune to O_after[n-1]; PQS stays up -------------------
  t0=$(now)
  sql "g$n-prune-dry" ok $DB "select * from prune_archived_to_offset_dry_run($OA)"
  sql "g$n-prune"     ok $DB "select * from prune_archived_to_offset($OA)"
  measure "g$n" cleanup_seconds "$(python3 -c "print(round($(now)-$t0,3))")"
  pqs_alive || die "PQS not running after prune"
  measure "g$n" pqs_running_through_cleanup yes
  mv_ "g$n" pruned_offset "g$n-pruned-offset" $DB "select pruned_offset()"
  measure_all "g$n-after-cleanup" $n $DB
done
LAST_OA=$OA   # O_after[3]: the last generation boundary pruned

# ---- A-recover: fresh re-ingest of the whole ledger, all DARs retained, then one prune ----------
pqs_stop
createdb_fresh adb_recover; pqs_start adb_recover; wait_pqs_offset adb_recover "$LASTTX"
measure_all recover-before-prune 4 adb_recover
sql recover-prune-dry ok adb_recover "select * from prune_archived_to_offset_dry_run($LAST_OA)"
sql recover-prune     ok adb_recover "select * from prune_archived_to_offset($LAST_OA)"
measure_all recover-after-prune 4 adb_recover
pqs_stop

# ---- A-cli: the CLI prune takes --postgres-* flags (not the pipeline's --target-postgres-*) ----
# Fresh re-ingest again, then dry run and Force through the CLI against port 5499 explicitly.
createdb_fresh adb_cli; pqs_start adb_cli; wait_pqs_offset adb_cli "$LASTTX"; pqs_stop
CLI=(java -jar "$JAR" datastore postgres-document prune --prune-target "$LAST_OA"
     --postgres-host localhost --postgres-port 5499 --postgres-database adb_cli
     --postgres-username postgres --postgres-password pw)
mv_ cli-before retired_creates cli-before adb_cli "select count(*) from creates('$M') where package_id <> '${ID[4]}'"
step cli-prune-dry   ok "${CLI[@]}"
mv_ cli-after-dry retired_creates cli-after-dry adb_cli "select count(*) from creates('$M') where package_id <> '${ID[4]}'"
step cli-prune-force ok "${CLI[@]}" --prune-mode Force
mv_ cli-after-force retired_creates cli-after-force adb_cli "select count(*) from creates('$M') where package_id <> '${ID[4]}'"
mv_ cli pruned_offset cli-pruned-offset adb_cli "select pruned_offset()"

sandbox_stop
echo "RUN A COMPLETE"
