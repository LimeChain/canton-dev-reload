#!/usr/bin/env bash
# LocalNet timing, RELOAD vs RESTART, same protocol as scripts/77-mn-timing.sh:
#   Reset   every trial starts from a fresh LocalNet (clean + start) with the v1 fixture (ln-fixture.canton),
#           built OUTSIDE the timed interval. Timeouts (LN_CONFIRM_S/LN_REACT_S) are set in the fixture.
#   Start   T0 = the v2 source is written (then built with dpm); both paths include the build.
#   End     SEEDED (epoch ms): v2 seeded (2 Shared + 1 Own per party) on both app nodes.
#   Reload  ln-timing-reload.canton in a fresh console JVM.
#   Restart make clean-localnet, make start-localnet, ln-timing-restart.canton (parties, rights, upload+vet v2, seed).
#   Order   paths alternate per trial; trial 1 of each path is a discarded warm-up. Failures reported, not retried.
#   Guards  aborts if the Mac is on battery (LN_ALLOW_BATTERY=1 for smoke tests only) or the disk has < 8 GB free. Docker logs capped (ln-logcap.yaml).
# usage: ln-timing.sh <label> [trials=11] [paths="reload restart"]
set -uo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/.." && pwd)"; Q="$R/.qs/quickstart"; M="$Q/docker/modules/localnet"
label="$1"; trials="${2:-11}"; paths="${3:-reload restart}"
O="$R/logs/ln-timing-$label"; mkdir -p "$O"; T="$O/trials.tsv"; : > "$T"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
up()   { (cd "$Q" && make start-localnet LOCALNET_ONLY_RESOURCE_CONSTRAINTS="-f $M/resource-constraints.yaml -f $L/ln-logcap.yaml" > "$O/compose-up.log" 2>&1); }
down() { (cd "$Q" && make clean-localnet > "$O/compose-down.log" 2>&1); }
src()  { cp "$R/variants/Shared.$1.daml" "$R/.gen-shared/v2/daml/Shared.daml"; }
build(){ src v2; (cd "$R/.gen-shared/v2" && dpm build -o "$R/artifacts/shared-v2.dar" > "$O/build.log" 2>&1); }
guard(){ [ -n "${LN_ALLOW_BATTERY:-}" ] || pmset -g batt | head -1 | grep -q "AC Power" || { echo "ABORT: on battery" | tee -a "$T"; down; src v1; exit 2; }
         local free; free=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}'); [ "$free" -ge 8 ] || { echo "ABORT: disk ${free}G free" | tee -a "$T"; down; src v1; exit 3; } }
fixture(){ local n="$1" p="$2" f="$O/$n-$p-fixture.out"
  down; up; rm -f "$L/state/fred.checkpoint"; src v1
  "$L/ln-run.sh" ln-fixture.canton ${LN_CONFIRM_S:+-e LN_CONFIRM_S=$LN_CONFIRM_S} ${LN_REACT_S:+-e LN_REACT_S=$LN_REACT_S} > "$f" 2>&1
  grep -q '^VERDICT PASS' "$f" && sed -n 's/^PKG V1=//p' "$f"; }
row(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$1" "$2" "$3" "$4" "$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')G" "$5" >> "$T"; tail -1 "$T"; }
sec(){ python3 -c "print(f'{($1-$2)/1000:.1f}')"; }

trial_reload(){ local n="$1" v1; guard; v1=$(fixture "$n" reload) || true
  [ -n "$v1" ] || { row "$n" reload - setup-failed "$n-reload-fixture.out"; return; }
  local t0 tb tc f="$O/$n-reload.out"; t0=$(ms); build || { row "$n" reload - build-failed ""; return; }; tb=$(ms)
  "$L/ln-run.sh" ln-timing-reload.canton -e LN_V1="$v1" > "$f" 2>&1; tc=$(ms)
  local s ok; s=$(sed -n 's/^SEEDED \([0-9]*\) .*/\1/p' "$f"); ok=$(sed -n 's/^SEEDED [0-9]* ok=//p' "$f")
  local split; split="build=$(sec $tb $t0) $(grep '^TIME' "$f" | awk '{printf "%s=%s ", $2, $3}')jvm_exit=$(sec $tc ${s:-$tc})"
  if [ -n "$s" ] && [ "$ok" = true ]; then row "$n" reload "$(sec $s $t0)" ok "$split"; else row "$n" reload - "failed(ok=$ok)" "$split"; fi; }

trial_restart(){ local n="$1" v1; guard; v1=$(fixture "$n" restart) || true
  [ -n "$v1" ] || { row "$n" restart - setup-failed "$n-restart-fixture.out"; return; }
  local t0 tb ts tu f="$O/$n-restart.out"; t0=$(ms); build || { row "$n" restart - build-failed ""; return; }; tb=$(ms)
  down; ts=$(ms); up; tu=$(ms); rm -f "$L/state/fred.checkpoint"
  "$L/ln-run.sh" ln-timing-restart.canton > "$f" 2>&1
  local s ok; s=$(sed -n 's/^SEEDED \([0-9]*\) .*/\1/p' "$f"); ok=$(sed -n 's/^SEEDED [0-9]* ok=//p' "$f")
  local split="build=$(sec $tb $t0) stop=$(sec $ts $tb) start=$(sec $tu $ts) setup=$(sec ${s:-$tu} $tu)"
  if [ -n "$s" ] && [ "$ok" = true ]; then row "$n" restart "$(sec $s $t0)" ok "$split"; else row "$n" restart - "failed(ok=$ok)" "$split"; fi; }

echo "LN timing [$label] confirm=${LN_CONFIRM_S:-default} react=${LN_REACT_S:-default} trials=$trials paths=$paths  $(date -u +%FT%TZ)"
for n in $(seq 1 "$trials"); do for p in $paths; do "trial_$p" "$n"; done; done
down; src v1
python3 - "$T" <<'PY'
import sys, statistics as st
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip() and not l.startswith("ABORT")]
for p in ("reload","restart"):
    rs=[r for r in rows if r[2]==p]; m=[float(r[3]) for r in rs if r[4]=="ok" and int(r[1])>1]
    if not rs: continue
    bad=[r[1] for r in rs if r[4]!="ok"]
    print(f"SUMMARY {p}: n={len(m)} median={st.median(m):.1f}s min={min(m):.1f} max={max(m):.1f} failed={bad}" if m else f"SUMMARY {p}: no measured trials, failed={bad}")
PY
