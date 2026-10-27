#!/usr/bin/env bash
# Edge cases: (2) empty setup after a reload -- prune refused until a later transaction exists;
# (3) a party allocated after PQS started -- visible without a PQS restart in all-parties mode?
RUN=${RUN_NAME:-E}; . "$(dirname "$0")/lib.sh"
ID=(_); for n in 1 2; do ID+=("$(awk -F'\t' -v k="A-g$n" '$1==k{print $4}' "$FIX/fixtures.tsv")"); done
DB=edb; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar con init ok c-init.canton
ITEMS=$(tval ITEMS); TX=$(tval LASTTX)
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX"
PKG=${ID[1]} TY=Text con g1-create ok c-create.canton; wait_pqs_offset $DB "$(tval LASTTX)"

# ---- Test 2: reload with an EMPTY setup ----
PKG=${ID[1]} con g2-archive-g1 ok c-archive.canton; OA=$(tval END); ARCH_TX=$(tval LASTTX); offset O_after_1 "$OA"
OLD=${ID[1]} NEW_DAR=$FIX/A-g2.dar con g2-swap ok c-swap.canton
wait_pqs_offset $DB "$ARCH_TX"
mv_ empty latest_checkpoint empty-latest $DB "select (latest_checkpoint()).offset"
measure empty prune_target "$OA"
nextlog empty-prune; _sql $DB "select * from prune_archived_to_offset($OA)" > "$LOG" 2>&1; rc=$?
printf '%s\tempty-prune\twant=outcome\tgot=%s\trc=%s\t-\t%s\n' "$N" "$([ $rc -eq 0 ] && echo accepted || echo refused)" "$rc" "$(basename "$LOG")" >> "$LOGDIR/steps.tsv"
measure empty prune_with_no_later_tx "$([ $rc -eq 0 ] && echo accepted || echo refused): $(grep -m1 -E 'ERROR' "$LOG" | cut -c1-140)"
mv_ empty retired_creates_still empty-retired $DB "select count(*) from creates('$M') where package_id <> '${ID[2]}'"
# a later transaction arrives (the next setup or test action), then the same prune succeeds
PKG=${ID[2]} TY=Int con g2-create-later ok c-create.canton; wait_pqs_offset $DB "$(tval LASTTX)"
sql later-prune ok $DB "select * from prune_archived_to_offset($OA)"
mv_ later retired_creates later-retired $DB "select count(*) from creates('$M') where package_id <> '${ID[2]}'"
mv_ later current_rows later-current $DB "select count(*) from active('$M') where package_id = '${ID[2]}'"

# ---- Test 3: a party allocated AFTER PQS started (PQS in its default all-parties mode) ----
measure party pqs_mode "$(grep -m1 -oE 'Starting pipeline on behalf of [a-z ]+' "$PQS_LOG")"
PARTY_NAME=Bob ITEMS=$ITEMS con bob-create ok c-party.canton; BOB_CID=$(tval CID); BOB_TX=$(tval LASTTX)
try_wait_pqs_offset $DB "$BOB_TX" 30
measure party checkpoint_reached_without_restart "$WAIT_RESULT"
mv_ party bob_contract_without_restart bob-norestart $DB "select count(*) from active('$I') where contract_id = '$BOB_CID'"
pqs_stop; pqs_start $DB; try_wait_pqs_offset $DB "$BOB_TX" 60
measure party checkpoint_after_restart "$WAIT_RESULT"
mv_ party bob_contract_after_restart bob-restart $DB "select count(*) from active('$I') where contract_id = '$BOB_CID'"
pqs_stop; sandbox_stop
echo "RUN E COMPLETE"
