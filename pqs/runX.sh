#!/usr/bin/env bash
# The Option B items the stopped B run could not reach, each an independent experiment on its own
# fresh PQS database over one full four-generation Option B ledger (mirrors 1.0.0..1.0.3):
#   B-recover  fresh database, complete final filter, all DARs retained
#   X1         reset below the pruning marker while an earlier anchor survives
#   X2         reset below the oldest surviving history
#   X3         one Option B clean-up after an Option A prune
RUN=${RUN_NAME:-X}; . "$(dirname "$0")/lib.sh"
TYPES=(_ Text Int Bool Decimal); VER=(_ 1.0.0 1.0.1 1.0.2 1.0.3)
ID=(_); for n in 1 2 3 4; do ID+=("$(awk -F'\t' -v k="B-g$n" '$1==k{print $4}' "$FIX/fixtures.tsv")"); done
M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
counts() {  # tag db
  mv_ "$1" g1_rows        "$1-g1"         "$2" "select count(*) from creates('$M') where package_id = '${ID[1]}'"
  mv_ "$1" retired_creates "$1-retired"   "$2" "select count(*) from creates('$M') where package_id <> '${ID[4]}'"
  mv_ "$1" current_rows   "$1-current"    "$2" "select count(*) from active('$M') where package_id = '${ID[4]}'"
  mv_ "$1" anchor         "$1-anchor"     "$2" "select count(*) from active('$I') where contract_id = '$ANCHOR'"
  mv_ "$1" collateral     "$1-collateral" "$2" "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"
}
checkpoints() {  # tag db
  mv_ "$1" oldest_checkpoint "$1-oldest" "$2" "select (oldest_checkpoint()).offset"
  mv_ "$1" latest_checkpoint "$1-latest" "$2" "select (latest_checkpoint()).offset"
  mv_ "$1" pruned_offset     "$1-pruned" "$2" "select coalesce(pruned_offset()::text,'none')"
}
# sql_outcome <name> <db> <sql> : run SQL whose success or refusal is the RESULT; record which.
sql_outcome() {
  local name="$1"; nextlog "$name"; local log="$LOG"
  _sql "$2" "$3" > "$log" 2>&1; local rc=$?; LAST_LOG="$log"
  OUTCOME=$([ $rc -eq 0 ] && echo accepted || echo refused)
  printf '%s\t%s\twant=outcome\tgot=%s\trc=%s\t-\t%s\n' "$N" "$name" "$OUTCOME" "$rc" "$(basename "$log")" >> "$LOGDIR/steps.tsv"
  DETAIL="$(grep -vE '^(CONTEXT|SQL statement|PL/pgSQL)' "$log" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-160)"
}

# ---- one full four-generation Option B ledger (no PQS clean-up; ledger only) ------------------
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/B-g1.dar con init ok c-init.canton
ANCHOR=$(tval ANCHOR); COLLATERAL=$(tval COLLATERAL)
con g1-before ok c-end.canton; OB=(_ "$(tval END)"); offset O_before_1 "${OB[1]}"
PKG=${ID[1]} TY=Text con g1-create ok c-create.canton
OA=(_)
for n in 2 3 4; do
  p=$((n-1))
  PKG=${ID[$p]} con "g$n-archive-g$p" ok c-archive.canton; OA+=("$(tval END)"); offset "O_after_$p" "$(tval END)"
  OLD=${ID[$p]} NEW_DAR=$FIX/B-g$n.dar con "g$n-swap" ok c-swap.canton
  con "g$n-before" ok c-end.canton; OB+=("$(tval END)"); offset "O_before_$n" "$(tval END)"
  PKG=${ID[$n]} TY=${TYPES[$n]} con "g$n-create" ok c-create.canton; LASTTX=$(tval LASTTX)
done

# ---- B-recover ---------------------------------------------------------------------------------
createdb_fresh x_recover
PQS_FILTER="(* & !mirrors:*) | mirrors@>=1.0.3" pqs_start x_recover
measure recover filter_applied "$(sleep 3; grep -m1 -E '^\s+contracts=' "$PQS_LOG" | sed 's/^ *//')"
try_wait_pqs_offset x_recover "$LASTTX" 90
measure recover outcome "$WAIT_RESULT"
[ "$WAIT_RESULT" = pqs-crashed ] && measure recover crash_cause "$(pqs_crash_cause)"
[ "$WAIT_RESULT" = caught-up ] && counts recover x_recover
pqs_stop

# ---- X1: target below the pruning marker, earlier anchor surviving ---------------------------
createdb_fresh x1; pqs_start x1; wait_pqs_offset x1 "$LASTTX"
counts x1-ingested x1
sql x1-prune ok x1 "select * from prune_archived_to_offset(${OA[1]})"
checkpoints x1-after-prune x1
counts x1-after-prune x1
pqs_stop
PRUNED=$(awk -F'\t' '$1=="x1-after-prune" && $2=="pruned_offset"{print $3}' "$LOGDIR/measures.tsv")
OLDEST=$(awk -F'\t' '$1=="x1-after-prune" && $2=="oldest_checkpoint"{print $3}' "$LOGDIR/measures.tsv")
T1=${OB[1]}   # O_before[1]: above the oldest surviving history, below the pruning marker
measure x1 target_vs_bounds "oldest=$OLDEST target=$T1 pruned=$PRUNED"
sql_outcome x1-validate x1 "select * from validate_reset_offset($T1)"; measure x1 validate "$OUTCOME: $DETAIL"
sql_outcome x1-reset x1 "select * from reset_to_offset($T1)"; measure x1 reset "$OUTCOME: $DETAIL"
checkpoints x1-after-reset x1
counts x1-after-reset-before-replay x1
pqs_start x1; try_wait_pqs_offset x1 "$LASTTX" 90; measure x1 unfiltered_replay "$WAIT_RESULT"
[ "$WAIT_RESULT" = caught-up ] && counts x1-after-replay x1
pqs_stop

# ---- X2: target below the oldest surviving history -------------------------------------------
createdb_fresh x2; pqs_start x2; wait_pqs_offset x2 "$LASTTX"
sql x2-prune ok x2 "select * from prune_archived_to_offset(${OA[2]})"
checkpoints x2-after-prune x2
pqs_stop
OLDEST=$(awk -F'\t' '$1=="x2-after-prune" && $2=="oldest_checkpoint"{print $3}' "$LOGDIR/measures.tsv")
T2=$((OLDEST - 1))
measure x2 target_vs_bounds "target=$T2 oldest=$OLDEST"
sql_outcome x2-validate x2 "select * from validate_reset_offset($T2)"; measure x2 validate "$OUTCOME: $DETAIL"
sql_outcome x2-reset x2 "select * from reset_to_offset($T2)"; measure x2 reset "$OUTCOME: $DETAIL"
checkpoints x2-after-reset x2

# ---- X3: one Option B clean-up after an Option A prune ---------------------------------------
createdb_fresh x3; pqs_start x3; wait_pqs_offset x3 "$LASTTX"
sql x3-prune-A ok x3 "select * from prune_archived_to_offset(${OA[3]})"
counts x3-after-A x3
pqs_stop
sql_outcome x3-validate x3 "select * from validate_reset_offset(${OB[3]})"; measure x3 validate "$OUTCOME: $DETAIL"
sql_outcome x3-reset x3 "select * from reset_to_offset(${OB[3]})"; measure x3 reset "$OUTCOME: $DETAIL"
checkpoints x3-after-reset x3
PQS_FILTER="(* & !mirrors:*) | mirrors@>=1.0.3" pqs_start x3
try_wait_pqs_offset x3 "$LASTTX" 90; measure x3 filtered_replay "$WAIT_RESULT"
[ "$WAIT_RESULT" = pqs-crashed ] && measure x3 crash_cause "$(pqs_crash_cause)"
[ "$WAIT_RESULT" = caught-up ] && counts x3-after-replay x3
pqs_stop
sandbox_stop
echo "RUN X COMPLETE"
