#!/usr/bin/env bash
# Prune at scale: SCALE archived g1 mirrors (+1000 active Items that must survive), one g1 -> g2
# reload, then a timed dry run and prune while a reader probe and an ingest probe run alongside.
SCALE=${SCALE:?}; RUN=S-$SCALE; . "$(dirname "$0")/lib.sh"
DB=sdb_$SCALE; M="mirrors:Mirrors:Mirror"; I="items:Items:Item"; BATCH=25
G2=$(awk -F'\t' '$1=="A-g2"{print $4}' "$FIX/fixtures.tsv")
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
T_RUN=$(ms)
assert_eq() { [ "$2" = "$3" ] && measure assert "$1" "ok ($2)" || die "assert $1: got '$2', want '$3'"; }
counts() {  # tag
  mv_ "$1" retired_creates "$1-retired" $DB "select count(*) from creates('$M') where package_id <> '$G2'"
  mv_ "$1" items_active "$1-items" $DB "select count(*) from active('$I')"
  mv_ "$1" g2_active "$1-g2" $DB "select count(*) from active('$M') where package_id = '$G2'"
  mv_ "$1" table_rows "$1-tables" $DB "select (select count(*) from __contracts)||' contracts, '||(select count(*) from __events)||' events, '||(select count(*) from __exercises)||' exercises, '||(select count(*) from __transactions)||' transactions'"
  mv_ "$1" db_size "$1-dbsize" $DB "select pg_size_pretty(pg_database_size(current_database()))||' ('||pg_database_size(current_database())||')'"
  sql "$1-relsizes" ok $DB "select relname, pg_total_relation_size(oid) from pg_class where relkind in ('r','p') and relname like '\_\_%' order by 2 desc limit 12"
}
timed_sql() {  # name sql : one psql session with \timing; server-reported ms -> TIMED_MS, wall -> TIMED_WALL
  nextlog "$1"; local t0 t1; t0=$(ms)
  printf '\\timing on\n%s;\n' "$2" | docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U postgres -d $DB -tA -F' | ' > "$LOG" 2>&1; local rc=$?
  t1=$(ms); TIMED_START=$t0; TIMED_END=$t1
  printf '%s\t%s\twant=ok\tgot=rc%s\t-\t%sms\t%s\n' "$N" "$1" "$rc" "$((t1-t0))" "$(basename "$LOG")" >> "$LOGDIR/steps.tsv"
  [ $rc -eq 0 ] || die "$1 failed, see $LOG"
  TIMED_MS=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' "$LOG" | tail -1); TIMED_WALL=$((t1-t0)); LAST_LOG="$LOG"
}

# ---- load ----
sandbox_start
ITEMS_DAR=$FIX/items-v1.dar G1_DAR=$FIX/A-g1.dar con init ok c-init.canton
ITEMS=$(tval ITEMS); G1=$(tval G1); TX0=$(tval LASTTX)
createdb_fresh $DB; pqs_start $DB; wait_pqs_offset $DB "$TX0"
T_LOAD=$(ms)
ITEMS=$ITEMS PHASE=items COUNT=1000 BATCH=$BATCH con items ok c-bulk.canton; measure load items_txs "$(tval TXS)"
G1=$G1 PHASE=churn COUNT=$SCALE BATCH=$BATCH con churn ok c-bulk.canton; measure load churn_txs "$(tval TXS)"
measure load console_load_seconds "$(( ($(ms) - T_LOAD) / 1000 ))"
con o-after ok c-end.canton; OA=$(tval END); offset O_after "$OA"
OLD=$G1 NEW_DAR=$FIX/A-g2.dar con swap ok c-swap.canton
G2=$G2 PHASE=g2 COUNT=2 BATCH=1 con g2-create ok c-bulk.canton; LT=$(tval LASTTX)
wait_pqs_offset $DB "$LT" 1800
measure load seconds_from_load_start_to_pqs_caught_up "$(( ($(ms) - T_LOAD) / 1000 ))"

# ---- before ----
counts before
assert_eq items_before "$(grep '^before	items_active' "$LOGDIR/measures.tsv" | cut -f3)" 1001

# reader probe: timestamp, timed count, 100 ms pause, repeated; one long-lived session
python3 - "$LOGDIR/reader.sql" "$I" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("\\timing on\n")
    for _ in range(4000):
        f.write("select 'T', (extract(epoch from clock_timestamp())*1000)::bigint;\n")
        f.write(f"select 'Q', count(*) from active('{sys.argv[2]}');\n")
        f.write("select pg_sleep(0.1);\n")
PY
docker cp "$LOGDIR/reader.sql" "$PG:/tmp/reader.sql" >/dev/null
docker exec "$PG" psql -U postgres -d $DB -tA -F' | ' -f /tmp/reader.sql > "$LOGDIR/reader.log" 2>&1 &
READER=$!
sleep 10

# ---- prune with the ingest probe ----
timed_sql prune-dry "select * from prune_archived_to_offset_dry_run($OA)"
measure prune dry_run_ms "$TIMED_MS"; measure prune dry_run_wall_ms "$TIMED_WALL"
PD="$LOGDIR/probe"; rm -rf "$PD"; mkdir -p "$PD"
nextlog ingest-probe; PROBE_LOG="$LOG"
( cat "$AB/common.sc" "$AB/c-probe.canton" > "$PD/run.canton"
  PROBE_DIR="$PD" ITEMS=$ITEMS COUNT=20 dpm canton-console -C canton.features.enable-preview-commands=yes \
    --bootstrap "$PD/run.canton" --no-tty < /dev/null ) > "$PROBE_LOG" 2>&1 &
PROBE=$!
for _ in $(seq 1 120); do [ -f "$PD/READY" ] && break; sleep 0.5; done
[ -f "$PD/READY" ] || die "ingest probe never became ready, see $PROBE_LOG"
( while :; do printf '%s\t%s\n' "$(ms)" "$(_sql $DB "select (latest_checkpoint()).offset" 2>/dev/null | tail -1)"; sleep 0.5; done ) > "$LOGDIR/ingest-checkpoints.tsv" &
SAMPLER=$!
touch "$PD/GO"
timed_sql prune "select * from prune_archived_to_offset($OA)"
measure prune prune_ms "$TIMED_MS"; measure prune prune_wall_ms "$TIMED_WALL"
measure prune start_end_ms "$TIMED_START $TIMED_END"
measure prune returned "$(grep -v '^Time' "$LAST_LOG" | grep '|' | tail -1)"
wait $PROBE; echo "probe rc=$?" >> "$PROBE_LOG"
PROBE_LAST=$(sed -n 's/^T LASTTX=//p' "$PROBE_LOG" | tail -1); [ -n "$PROBE_LAST" ] || die "ingest probe failed, see $PROBE_LOG"
sleep 10; kill $READER 2>/dev/null; docker exec "$PG" pkill -f reader.sql 2>/dev/null
wait_pqs_offset $DB "$PROBE_LAST" 300; kill $SAMPLER 2>/dev/null
measure prune pqs_alive_after "$(pqs_alive && echo yes || echo no)"

# ---- ingest and reader analysis ----
python3 - "$PROBE_LOG" "$LOGDIR/ingest-checkpoints.tsv" "$LOGDIR/reader.log" "$TIMED_START" "$TIMED_END" > "$LOGDIR/analysis.txt" <<'PY'
import sys, statistics
probe, cps, reader, ps, pe = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
p = [tuple(map(int, l.strip()[4:].split(","))) for l in open(probe) if l.startswith("T P=")]
first_off, first_ms = p[0]; last_off = p[-1][0]
print(f"probe_txs={len(p)}")
print(f"probe_first_submitted_ms_after_prune_start={first_ms-ps}")
print(f"probe_last_submitted_ms_after_prune_start={p[-1][1]-ps}")
samples = []
for l in open(cps):
    t, _, c = l.rstrip("\n").partition("\t")
    if c.strip().isdigit(): samples.append((int(t), int(c)))
def first(off):
    for t, c in samples:
        if c >= off: return t
seen1, seenN = first(first_off), first(last_off)
print(f"prune_duration_ms={pe-ps}")
print(f"pqs_ingested_first_probe_tx_ms_after_prune_start={seen1-ps if seen1 else 'not-in-samples'}")
print(f"pqs_ingested_first_probe_tx_during_prune={'yes' if seen1 and seen1 < pe else 'no'}")
print(f"pqs_ingested_last_probe_tx_ms_after_prune_end={seenN-pe if seenN else 'not-in-samples'}")
lat = []; ts = None; pending = None; state = None
for l in open(reader):
    l = l.strip()
    if l.startswith("T | "): ts = int(l.split("|")[1]); state = "T"
    elif l.startswith("Q | "): state = "Q"
    elif l.startswith("Time:") and state == "Q":
        lat.append((ts, float(l.split()[1]))); state = None
    elif l.startswith("Time:"): state = None
def stats(xs):
    xs = [x for _, x in xs]
    return f"n={len(xs)} p50={statistics.median(xs):.1f}ms max={max(xs):.1f}ms" if xs else "n=0"
print(f"reader_baseline={stats([x for x in lat if x[0] < ps])}")
print(f"reader_during_prune={stats([x for x in lat if ps <= x[0] <= pe])}")
print(f"reader_after={stats([x for x in lat if x[0] > pe])}")
# a query that started before the prune ended and finished after it overlaps it too
print(f"reader_overlapping_prune={stats([x for x in lat if x[0] <= pe and x[0] + x[1] >= ps])}")
PY
while IFS='=' read -r k v; do measure ingest_reader "$k" "$v"; done < "$LOGDIR/analysis.txt"

# ---- after ----
counts after
assert_eq retired_after "$(grep '^after	retired_creates' "$LOGDIR/measures.tsv" | cut -f3)" 0
assert_eq items_after "$(grep '^after	items_active' "$LOGDIR/measures.tsv" | cut -f3)" 1021   # 1001 + 20 probe items
assert_eq g2_after "$(grep '^after	g2_active' "$LOGDIR/measures.tsv" | cut -f3)" 2
mv_ after pruned_offset after-pruned $DB "select pruned_offset()"; assert_eq pruned_offset "$VAL" "$OA"
pqs_alive || die "PQS not running after the prune"
pqs_stop; sandbox_stop
measure run total_seconds "$(( ($(ms) - T_RUN) / 1000 ))"
echo "RUN S-$SCALE COMPLETE"
