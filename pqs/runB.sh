#!/usr/bin/env bash
# Option B, as the reviewer describes it: per reload, stop PQS, revoke + terminate connections,
# reset_to_offset(O_before[N-1]) (before the RETIRING generation's first create), restore access,
# restart PQS with a version filter. Fixtures bump the version: g1..g4 = mirrors 1.0.0..1.0.3.
# A real read-only role (pqs_reader) probes the client impact. Then B-recover.
RUN=${RUN_NAME:-B}; . "$(dirname "$0")/lib.sh"
TYPES=(_ Text Int Bool Decimal); VER=(_ 1.0.0 1.0.1 1.0.2 1.0.3)
ID=(_); for n in 1 2 3 4; do ID+=("$(awk -F'\t' -v k="B-g$n" '$1==k{print $4}' "$FIX/fixtures.tsv")"); done
DB=bdb; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"
admin() { docker exec "$PG" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -tA -c "$1"; }
reader_select() { _sql "$DB" "select 1" pqs_reader; }

measure_all() {  # tag gen db
  local tag="$1" cur="${ID[$2]}" db="$3"
  mv_ "$tag" retired_active  "$tag-retired-active"  "$db" "select count(*) from active('$M') where package_id <> '$cur'"
  mv_ "$tag" retired_creates "$tag-retired-creates" "$db" "select count(*) from creates('$M') where package_id <> '$cur'"
  mv_ "$tag" current_rows    "$tag-current"         "$db" "select count(*) from active('$M') where package_id = '$cur'"
  mv_ "$tag" anchor          "$tag-anchor"          "$db" "select count(*) from active('$I') where contract_id = '$ANCHOR'"
  mv_ "$tag" collateral      "$tag-collateral"      "$db" "select count(*) from creates('$I') where contract_id = '$COLLATERAL'"
}
# assert_eq <tag> <name> <got> <want> : a RESULT check, recorded (not a setup failure, so no stop).
assert_eq() { local r=PASS; [ "$3" = "$4" ] || r=FAIL; measure "$1" "assert_$2" "$r got=$3 want=$4"; }
checkpoints() {  # tag
  mv_ "$1" oldest_checkpoint "$1-oldest" $DB "select (oldest_checkpoint()).offset"
  mv_ "$1" latest_checkpoint "$1-latest" $DB "select (latest_checkpoint()).offset"
  mv_ "$1" pruned_offset     "$1-pruned" $DB "select coalesce(pruned_offset()::text,'none')"
}

sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/B-g1.dar con init ok c-init.canton
ANCHOR=$(tval ANCHOR); COLLATERAL=$(tval COLLATERAL); TX=$(tval LASTTX)
[ "$(tval G1)" = "${ID[1]}" ] || die "uploaded g1 id $(tval G1) != fixture ${ID[1]}"
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX"
# Reader role: a normal login with CONNECT on the test database and SELECT on PQS's schema.
step reader-role ok admin "do \$\$ begin if not exists (select from pg_roles where rolname='pqs_reader') then create role pqs_reader login password 'reader'; end if; end \$\$"
sql reader-grants ok $DB "grant connect on database $DB to pqs_reader; grant usage on schema public to pqs_reader; grant select on all tables in schema public to pqs_reader; alter default privileges in schema public grant select on tables to pqs_reader"
step reader-probe ok reader_select

con g1-before ok c-end.canton; offset O_before_1 "$(tval END)"; OB=(_ "$(tval END)")
PKG=${ID[1]} TY=Text con g1-create ok c-create.canton; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
measure_all g1 1 $DB

for n in 2 3 4; do
  p=$((n-1))
  PKG=${ID[$p]} con "g$n-archive-g$p" ok c-archive.canton; offset "O_after_$p" "$(tval END)"
  OLD=${ID[$p]} NEW_DAR=$FIX/B-g$n.dar con "g$n-swap" ok c-swap.canton
  [ "$(tval NEW)" = "${ID[$n]}" ] || die "swapped-in id $(tval NEW) != fixture ${ID[$n]}"
  con "g$n-before" ok c-end.canton; offset "O_before_$n" "$(tval END)"; OB+=("$(tval END)")
  PKG=${ID[$n]} TY=${TYPES[$n]} con "g$n-create" ok c-create.canton; LASTTX=$(tval LASTTX); wait_pqs_offset $DB "$LASTTX"
  measure_all "g$n-before-cleanup" $n $DB

  # ---- Option B clean-up --------------------------------------------------------------------
  t0=$(now)
  # 1. a long-lived reader session, its own log and exit code
  nextlog "g$n-reader-session"; RLOG="$LOG"
  ( docker exec -e PGPASSWORD=reader "$PG" psql -h 127.0.0.1 -U pqs_reader -d $DB -c "select pg_sleep(600)" > "$RLOG" 2>&1; echo "exit=$?" >> "$RLOG" ) &
  RPID=$!
  for _ in $(seq 1 20); do [ "$(admin "select count(*) from pg_stat_activity where datname='$DB' and usename='pqs_reader'")" -ge 1 ] && break; sleep 0.5; done
  mv_ "g$n" reader_sessions_before "g$n-reader-before" $DB "select count(*) from pg_stat_activity where datname='$DB' and usename='pqs_reader'"
  # 2. stop PQS
  pqs_stop; t_down=$(now)
  # 3. revoke, 4. terminate (separate operations, per DA's reset procedure)
  t_revoke=$(now)
  step "g$n-revoke" ok admin "revoke connect on database $DB from public, pqs_reader"
  step "g$n-terminate" ok admin "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname='$DB' and pid <> pg_backend_pid()"
  # 5. verify the disconnect: existing reader terminated, fresh reader refused
  for _ in $(seq 1 20); do kill -0 $RPID 2>/dev/null || break; sleep 0.5; done
  kill -0 $RPID 2>/dev/null && die "reader session still alive after terminate"
  measure "g$n" reader_existing_session "$(tr '\n' ' ' < "$RLOG" | sed 's/  */ /g' | cut -c1-160)"
  step "g$n-reader-refused" fail reader_select
  measure "g$n" reader_fresh_connection "$(head -1 "$LAST_LOG" | cut -c1-140)"
  # 6. reset to O_before[n-1] (before the retiring generation's first create)
  checkpoints "g$n-pre-reset"
  measure "g$n" reset_requested "${OB[$p]}"
  sql "g$n-validate-reset" ok $DB "select * from validate_reset_offset(${OB[$p]})"
  measure "g$n" validate_reset_result "$(grep -v '^NOTICE' "$LAST_LOG" | tr '\n' ' ' | cut -c1-120)"
  sql "g$n-reset" ok $DB "select * from reset_to_offset(${OB[$p]})"
  measure "g$n" reset_result "$(grep -v '^NOTICE' "$LAST_LOG" | tr '\n' ' ' | cut -c1-120)"
  checkpoints "g$n-post-reset"
  # 7. restore access, verify a fresh reader connects, time it
  step "g$n-grant" ok admin "grant connect on database $DB to public, pqs_reader"
  step "g$n-reader-reconnect" ok reader_select
  measure "g$n" reader_unavailable_seconds "$(python3 -c "print(round($(now)-$t_revoke,3))")"
  # 8. restart PQS with the version filter
  FILTER="(* & !mirrors:*) | mirrors@>=${VER[$n]}"
  PQS_FILTER="$FILTER" pqs_start $DB
  wait_pqs_offset $DB "$LASTTX" 120
  measure "g$n" filter_applied "$(grep -m1 -E '^\s+contracts=' "$PQS_LOG" | sed 's/^ *//')"
  measure "g$n" filter "$FILTER"
  measure "g$n" filter_log "$(grep -oE 'Contract filter inclusive of [0-9]+ templates and [0-9]+ interfaces' "$PQS_LOG" | tail -1)"
  measure "g$n" pqs_downtime_seconds "$(python3 -c "print(round($(now)-$t_down,3))")"
  measure "g$n" cleanup_seconds "$(python3 -c "print(round($(now)-$t0,3))")"
  # 9. assert the replay before counting it as successful
  measure_all "g$n-after-cleanup" $n $DB
  R=$(awk -F'\t' -v t="g$n-after-cleanup" '$1==t{print $2"="$3}' "$LOGDIR/measures.tsv")
  assert_eq "g$n" no_retired_creates "$(echo "$R" | sed -n 's/^retired_creates=//p')" 0
  assert_eq "g$n" current_rows       "$(echo "$R" | sed -n 's/^current_rows=//p')" 2
  assert_eq "g$n" anchor_kept        "$(echo "$R" | sed -n 's/^anchor=//p')" 1
  assert_eq "g$n" collateral_kept    "$(echo "$R" | sed -n 's/^collateral=//p')" 1
done

# ---- B-recover: fresh database, complete final filter, all DARs retained ----------------------
pqs_stop
createdb_fresh bdb_recover
FILTER="(* & !mirrors:*) | mirrors@>=1.0.3"
PQS_FILTER="$FILTER" pqs_start bdb_recover; wait_pqs_offset bdb_recover "$LASTTX" 120
measure recover filter_applied "$(grep -m1 -E '^\s+contracts=' "$PQS_LOG" | sed 's/^ *//')"
measure recover filter "$FILTER"
measure_all recover 4 bdb_recover
R=$(awk -F'\t' '$1=="recover"{print $2"="$3}' "$LOGDIR/measures.tsv")
assert_eq recover no_retired_creates "$(echo "$R" | sed -n 's/^retired_creates=//p')" 0
assert_eq recover current_rows       "$(echo "$R" | sed -n 's/^current_rows=//p')" 2
assert_eq recover anchor_kept        "$(echo "$R" | sed -n 's/^anchor=//p')" 1
assert_eq recover collateral_kept    "$(echo "$R" | sed -n 's/^collateral=//p')" 1
pqs_stop
sandbox_stop
echo "RUN B COMPLETE"
