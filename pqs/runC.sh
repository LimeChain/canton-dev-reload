#!/usr/bin/env bash
# Compatible (SCU) reload with PQS attached: g1 (1.0.0) -> g2 (1.0.1, + note, + Bump) -> g3 (1.0.2,
# + tag), uploaded and vetted the normal way, nothing archived by the reload itself. Upgraded use of
# old contracts, one prune, and a fresh re-ingest compared row for row.
RUN=${RUN_NAME:-C}; . "$(dirname "$0")/lib.sh"
fx() { awk -F'\t' -v k="$1" '$1==k{print $4}' "$FIX/fixtures.tsv"; }
G1=$(fx A-g1); G2=$(fx C-g2); G3=$(fx C-g3)
DB=cdb; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
cc() { con "$1" ok c-compat.canton; }  # env set by the caller's prefix assignments

# snap <name> <db> <sql> : complete ordered result saved as snap-<name>.tsv, row count measured.
snap() {
  sql "snap-$1" ok "$2" "$3"
  grep -v '^NOTICE' "$LAST_LOG" > "$LOGDIR/snap-$1.tsv"
  measure snap "$1-rows" "$(grep -c . "$LOGDIR/snap-$1.tsv")"
}
ACTIVE_Q="select contract_id, package_id, package_version, payload::text from active('$M') order by contract_id"
per_pkg() {  # tag db
  mv_ "$1" active_g1 "$1-g1" "$2" "select count(*) from active('$M') where package_id = '$G1'"
  mv_ "$1" active_g2 "$1-g2" "$2" "select count(*) from active('$M') where package_id = '$G2'"
  mv_ "$1" active_g3 "$1-g3" "$2" "select count(*) from active('$M') where package_id = '$G3'"
}
field_groups() {  # tag db field
  mv_ "$1" "$3_groups" "$1-$3-groups" "$2" "select coalesce(string_agg(g || '=' || n, ',' order by g), '') from (select coalesce(payload->>'$3', 'NULL') g, count(*) n from active('$M') group by 1) t"
}
errors() { measure pqs "$1_error_lines" "$(grep -c 'ERROR' "$PQS_LOG")"; measure pqs "$1_pid_alive" "$(pqs_alive && echo yes || echo no)"; }

sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar con init ok c-init.canton
ANCHOR=$(tval ANCHOR); COLLATERAL=$(tval COLLATERAL); TX=$(tval LASTTX)
[ "$(tval G1)" = "$G1" ] || die "uploaded g1 $(tval G1) != fixture $G1"
createdb_fresh $DB; pqs_start $DB ${PQS_EXTRA:-}; ORIG_PID=$PQS_PID; wait_pqs_offset $DB "$TX"

# ---- g1: three old contracts ----
G1=$G1 PHASE=g1-create cc g1-create; M1=$(tval M1); M2=$(tval M2); M3=$(tval M3); wait_pqs_offset $DB "$(tval LASTTX)"
measure ids m1_m2_m3 "$M1 $M2 $M3"

# ---- compatible reload to g2 (upload + vet, both stay vetted, nothing archived) ----
G1=$G1 G2_DAR=$FIX/C-g2.dar M1=$M1 M2=$M2 M3=$M3 PHASE=g2-reload cc g2-reload
[ "$(tval NEW)" = "$G2" ] || die "g2 id $(tval NEW) != $G2"
measure g2 topology_transactions "$(tval TOPO_DELTA)"; measure g2 old_active_after_reload "$(tval OLD_ACTIVE)"
G2=$G2 M1=$M1 M2=$M2 M3=$M3 PHASE=g2-use cc g2-use; M1_NEW=$(tval M1_NEW); TX2=$(tval LASTTX)
measure ids m1_replacement "$M1_NEW"
wait_pqs_offset $DB "$TX2"; errors after_g2
measure pqs same_process_after_g2 "$([ "$PQS_PID" = "$ORIG_PID" ] && pqs_alive && echo yes || echo no)"

# ---- g2 measurements (before any prune) ----
per_pkg g2 $DB
snap g2-active $DB "$ACTIVE_Q"
mv_ g2 m3_has_note_key g2-m3-notekey $DB "select (payload ? 'note')::text || ' ' || package_id from active('$M') where contract_id = '$M3'"
field_groups g2 $DB note
snap g2-bump-m1 $DB "select 'exercise', contract_id, choice, consuming::text, package_id, package_version from exercises() where contract_id = '$M1' union all select 'created', contract_id, '', '', package_id, payload::text from creates('$M') where contract_id = '$M1_NEW' order by 1 desc"
snap g2-m2 $DB "select 'exercise', choice, consuming::text, package_id from exercises() where contract_id = '$M2' union all select 'create', coalesce(archived_at_offset::text,'not-archived'), '', package_id from creates('$M') where contract_id = '$M2' order by 1"
mv_ g2 m1_m2_active g2-m1m2-active $DB "select count(*) from active('$M') where contract_id in ('$M1','$M2')"
mv_ g2 anchor g2-anchor $DB "select count(*) from active('$I') where contract_id = '$ANCHOR'"
mv_ g2 collateral g2-collateral $DB "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"

# ---- prune ----
con prune-at ok c-end.canton; O=$(tval END); offset O "$O"
G2=$G2 PHASE=g2-later cc g2-later; wait_pqs_offset $DB "$(tval LASTTX)"
sql prune-dry ok $DB "select * from prune_archived_to_offset_dry_run($O)"
sql prune ok $DB "select * from prune_archived_to_offset($O)"
per_pkg prune $DB
snap prune-active $DB "$ACTIVE_Q"
mv_ prune m1_m2_creates prune-m1m2-creates $DB "select count(*) from creates('$M') where contract_id in ('$M1','$M2')"
mv_ prune m1_m2_exercises prune-m1m2-ex $DB "select count(*) from exercises() where contract_id in ('$M1','$M2')"
mv_ prune m3_still_g1 prune-m3 $DB "select count(*) || ' ' || coalesce(max(package_id),'') from active('$M') where contract_id = '$M3'"
mv_ prune anchor prune-anchor $DB "select count(*) from active('$I') where contract_id = '$ANCHOR'"
mv_ prune collateral prune-collateral $DB "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"
mv_ prune pruned_offset prune-offset $DB "select pruned_offset()"

# ---- second compatible reload to g3 ----
G1=$G1 G2=$G2 G3_DAR=$FIX/C-g3.dar M3=$M3 PHASE=g3 cc g3
[ "$(tval NEW)" = "$G3" ] || die "g3 id $(tval NEW) != $G3"
measure g3 topology_transactions "$(tval TOPO_DELTA)"; M3_NEW=$(tval M3_NEW); C7=$(tval C7); R=$(tval LASTTX); offset R "$R"
measure ids m3_replacement_c7 "$M3_NEW $C7"
wait_pqs_offset $DB "$R"; errors after_g3
measure pqs same_process_after_g3 "$([ "$PQS_PID" = "$ORIG_PID" ] && pqs_alive && echo yes || echo no)"
per_pkg g3 $DB
snap g3-bump-m3 $DB "select 'exercise', contract_id, choice, consuming::text, package_id, package_version from exercises() where contract_id = '$M3' union all select 'created', contract_id, '', '', package_id, payload::text from creates('$M') where contract_id = '$M3_NEW' order by 1 desc"
mv_ g3 m3_active g3-m3-active $DB "select count(*) from active('$M') where contract_id = '$M3'"
mv_ g3 m1_replacement_pkg_tagkey g3-m1new $DB "select package_id || ' tagkey=' || (payload ? 'tag')::text from active('$M') where contract_id = '$M1_NEW'"
mv_ g3 tag_null g3-tag-null $DB "select count(*) from active('$M') where payload->>'tag' is null"
mv_ g3 tag_7 g3-tag-7 $DB "select count(*) from active('$M') where payload->>'tag' = '7'"
field_groups g3 $DB note
measure pqs initialised_packages "$(grep -oE "Initialised [0-9]+ packages" "$PQS_LOG" | awk "{print \$2}" | paste -sd, -)"
grep -iE 'reload|unknown package|fetch.*package|ERROR' "$PQS_LOG" > "$LOGDIR/pqs-reload-lines.txt" || true

# ---- Q6: original vs fresh re-ingest, active sets at the same offset R ----
snap orig-active $DB "$ACTIVE_Q"
pqs_stop; pqs_alive && die "original PQS still alive"; measure q6 original_stopped yes
createdb_fresh ${DB}_recover; pqs_start ${DB}_recover ${PQS_EXTRA:-}; wait_pqs_offset ${DB}_recover "$R"
snap recover-active ${DB}_recover "$ACTIVE_Q"
mv_ q6 recover_all_creates q6-rec-creates ${DB}_recover "select count(*) from creates('$M')"
mv_ q6 orig_all_creates q6-orig-creates $DB "select count(*) from creates('$M')"
pqs_stop
if diff "$LOGDIR/snap-orig-active.tsv" "$LOGDIR/snap-recover-active.tsv" > "$LOGDIR/q6.diff"; then measure q6 active_sets identical
else measure q6 active_sets differs; fi
sandbox_stop
echo "RUN C COMPLETE"
