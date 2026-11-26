#!/usr/bin/env bash
# Timing on the 2-participant / 2-synchronizer topology: coordinated RELOAD vs RESTART, same protocol
# as scripts/80-timing.sh, adapted (docs/test-plan-multinode-purge.md, "Timing"):
#   Start   T0 = the v2 source is written (then built); both paths include the build.
#   End     the v2 seeded state is reached and checked: 2 Shared + 1 Own per party on v2 on both nodes
#           (SEEDED line, epoch ms, printed by the process that did the seeding).
#   Reset   every trial, warm-ups included, starts from a freshly started v1 topology with fresh setup,
#           built OUTSIDE the timed interval. Nothing carries over.
#   Reload  upload v2 unvetted, quiesce (rate 0), drain, purge on both nodes, 4 swaps, restore, setup v2.
#   Restart stop the topology, start a new one (new synchronizers, new parties), upload+vet v2, setup v2.
#   Order   paths alternate; the first trial of each path is a discarded warm-up.
#   Stat    median over the measured trials per path, min/max; failed trials are reported, never retried.
# PROTOTYPE: the reload runs as a fresh console JVM per reload, the restart as a fresh Canton JVM; both
# are prototype costs. The drain is bounded by the synchronizer's confirmationResponseTimeout +
# mediatorReactionTimeout (+5s margin, +6s ACS stability probe), set via MN_CONFIRM_S / MN_REACT_S.
#
# usage: 77-mn-timing.sh [TRIALS] [CONFIG_LABEL]     default 11 (1 warm-up + 10 measured), label "fixture"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh
trials="${1:-11}"; label="${2:-fixture}"
TAG="timing-$label"; . scripts/mn-daemon-lib.sh
export MN_SKIP_V2=1
OUT="$D_DIR/trials.tsv"; : > "$OUT"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
GEN=.gen-shared/v2

reset_source() { cp variants/Shared.v1.daml "$GEN/daml/Shared.daml"; }   # outside the timed interval
write_and_build() {                                                       # inside: the developer's save + build
  cp variants/Shared.v2.daml "$GEN/daml/Shared.daml"
  (cd "$GEN" && dpm build -o ../../artifacts/shared-v2.dar > "$D_DIR/build.log" 2>&1)
}

trial_reload() { local n="$1"
  MN_DAEMON_FIXTURE=console/mn-daemon.canton mn_daemon_start > /dev/null || { echo "$label	$n	reload	-	setup-failed" >> "$OUT"; return; }
  reset_source
  local t0; t0=$(ms)
  write_and_build || { echo "$label	$n	reload	-	build-failed" >> "$OUT"; mn_daemon_stop; return; }
  rcon "reload-$n" console/mn-timing-reload.canton > /dev/null
  local seeded ok; seeded="$(sed -n 's/^SEEDED \([0-9]*\) .*/\1/p' "$D_DIR/$RNAME.out")"; ok="$(sed -n 's/^SEEDED [0-9]* ok=//p' "$D_DIR/$RNAME.out")"
  local split; split="$(grep '^TIME' "$D_DIR/$RNAME.out" | awk '{printf "%s=%s ", $2, $3}')"
  if [ -n "$seeded" ] && [ "$ok" = true ]; then
    printf '%s\t%s\treload\t%.1f\tok\t%s\n' "$label" "$n" "$(python3 -c "print(($seeded-$t0)/1000)")" "$split" >> "$OUT"
  else printf '%s\t%s\treload\t-\tfailed(ok=%s)\t%s\n' "$label" "$n" "$ok" "$RNAME" >> "$OUT"; fi
  mn_daemon_stop
}

trial_restart() { local n="$1"
  MN_DAEMON_FIXTURE=console/mn-daemon.canton mn_daemon_start > /dev/null || { echo "$label	$n	restart	-	setup-failed" >> "$OUT"; return; }
  reset_source
  local t0; t0=$(ms)
  write_and_build || { echo "$label	$n	restart	-	build-failed" >> "$OUT"; mn_daemon_stop; return; }
  # stop the running topology (graceful, wait for exit), then bring a new one up seeded on v2
  kill "$DAEMON_PID"; while kill -0 "$DAEMON_PID" 2>/dev/null; do sleep 0.2; done
  local t_stopped; t_stopped=$(ms)
  rm -rf "$MN_H2_DIR"; mkdir -p "$MN_H2_DIR"
  cat console/mn-lib.canton console/mn-daemon-v2.canton > "$D_DIR/daemon-v2.canton"; : > "$D_DIR/daemon.canton.log"
  java -jar "$JAR" daemon -c canton/multinode.conf --bootstrap "$D_DIR/daemon-v2.canton" \
    --log-file-name "$D_DIR/daemon.canton.log" > "$D_DIR/daemon.out" 2>&1 < /dev/null &
  DAEMON_PID=$!
  for _ in $(seq 1 1800); do grep -q "^MN READY" "$D_DIR/daemon.out" && break; kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.2; done
  local seeded ok; seeded="$(sed -n 's/^SEEDED \([0-9]*\) .*/\1/p' "$D_DIR/daemon.out")"; ok="$(sed -n 's/^SEEDED [0-9]* ok=//p' "$D_DIR/daemon.out")"
  if [ -n "$seeded" ] && [ "$ok" = true ]; then
    printf '%s\t%s\trestart\t%.1f\tok\tbuild+stop=%.1f start+seed=%.1f\n' "$label" "$n" "$(python3 -c "print(($seeded-$t0)/1000)")" \
      "$(python3 -c "print(($t_stopped-$t0)/1000)")" "$(python3 -c "print(($seeded-$t_stopped)/1000)")" >> "$OUT"
  else printf '%s\t%s\trestart\t-\tfailed(ok=%s)\tdaemon.out\n' "$label" "$n" "$ok" >> "$OUT"; fi
  mn_daemon_stop
}

banner "timing [$label] confirm=${MN_CONFIRM_S:-30}s react=${MN_REACT_S:-10}s, $trials trials per path, alternating"
for n in $(seq 1 "$trials"); do
  trial_reload "$n";  tail -1 "$OUT"
  trial_restart "$n"; tail -1 "$OUT"
done
reset_source   # leave the generated project at v1

python3 - "$OUT" <<'EOF'
import sys, statistics as st
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
res={}
for label,n,path,dur,status,*_ in rows:
    if int(n)==1: continue                      # warm-up
    res.setdefault(path,{"ok":[],"bad":0})
    if status=="ok": res[path]["ok"].append(float(dur))
    else: res[path]["bad"]+=1
print()
for path in ("reload","restart"):
    r=res.get(path,{"ok":[],"bad":0}); v=r["ok"]
    if v: print(f"RESULT {path:8s} n={len(v)} failed={r['bad']} median={st.median(v):.1f}s min={min(v):.1f}s max={max(v):.1f}s")
    else: print(f"RESULT {path:8s} n=0 failed={r['bad']}")
a=res.get("reload",{}).get("ok",[]); b=res.get("restart",{}).get("ok",[])
if len(a)>=10 and len(b)>=10:
    print(f"RESULT reload vs restart: {100*(1-st.median(a)/st.median(b)):+.1f}% time saved (positive = reload faster)")
else:
    print("RESULT comparison not stated: fewer than 10 successful measured trials on a path")
EOF
