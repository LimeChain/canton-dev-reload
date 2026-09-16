#!/usr/bin/env bash
# Measure the inner-loop cost of a breaking model change, two ways, under one protocol.
#
#   reload   archive -> upload unvetted -> atomic vetting swap -> reseed -> verify
#   restart  restart the participant -> upload vetted -> seed (NEW parties) -> verify
#
# PROTOCOL (this is the contract the evidence log has to state, so it lives here in full):
#
#   Start event   the moment the changed source is written. scripts/05-variant.sh records it to
#                 logs/t0.source-write immediately before copying the variant into the generated
#                 project, so T0 is a captured event, not a timestamp reconstructed afterwards.
#   End event     an EQUIVALENT LOGICAL SEEDED STATE -- parties exist and the seed data is
#                 verified (console/verify-seeded.canton). The restart path reaches it with NEWLY
#                 ALLOCATED party ids, and that is permitted: the condition is logical
#                 equivalence, not identity.
#   Excluded      the work of repairing scripts/config/fixtures that still hold the OLD party ids
#                 after a restart. That cost is real and is the proposal's qualitative argument,
#                 but it is unbounded and project-specific, so folding it in would inflate the
#                 figure with something that cannot be standardised. The measured advantage is
#                 therefore a CONSERVATIVE FLOOR.
#   Reset         every trial starts from a fresh in-memory sandbox, a rebuilt v1 and a fresh
#                 seed -- performed OUTSIDE the timed interval. Neither path is repeatable in
#                 place: a reload mutates v1 into v2, a restart destroys and reallocates state.
#   Direction     always v1 -> v2 (Text -> Int). The reverse is not a symmetric operation and its
#                 trials would not be comparable.
#   Order         paths alternate, so machine drift affects both equally.
#   Warm-up       the first trial of each path is discarded; build and JVM caches stay warm
#                 thereafter, which is the realistic inner-loop condition.
#   Statistic     median over the measured trials per path, with min/max reported.
#
# PROTOTYPE, NOT PRODUCT: `dpm dev-reload` is the Milestone 1 deliverable and does not exist.
# These trials time the existing shell/console orchestration. Every figure is prototype timing.
#
# usage: 80-timing.sh [TRIALS]      default 11 per path (1 warm-up + 10 measured)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

trials="${1:-11}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="evidence/${stamp}__TIMING__reload-vs-restart.log"
mkdir -p evidence
exec > >(tee "$log") 2>&1

now() { date +%s.%N; }
# Pass via argv, not string interpolation: nesting quotes inside an f-string inside a double-quoted
# shell string produces invalid Python and silently fails the trial.
elapsed() { python3 -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "$1" "$2"; }

echo "#### TIMING  reload vs restart-and-reseed"
echo "#### trials=$trials per path (first of each discarded as warm-up)"
echo "#### PROTOTYPE TIMING -- dpm dev-reload does not exist; this is the shell/console harness"
echo

banner "provenance"
bash scripts/env-stamp.sh; stamp_rc=$?
[ "$stamp_rc" -eq 1 ] && { echo "VOID provenance failed"; exit 1; }

# Untimed. Returns a sandbox running v1, seeded, with the v1 seed DAR preserved for archiving.
reset_to_v1() {
  bash scripts/00-sandbox.sh >/dev/null 2>&1 || return 1
  bash scripts/05-variant.sh v1 >/dev/null 2>&1 || return 1
  cp artifacts/mirrors-seed.dar artifacts/mirrors-seed-v1.dar
  POC_MODEL_DAR=artifacts/mirrors-v1.dar POC_SEED_DAR=artifacts/mirrors-seed-v1.dar \
    bash scripts/10-seed.sh >/dev/null 2>&1 || return 1
}

verify_seeded() { console console/verify-seeded.canton 180 2>&1 | grep -q "VERIFY ok"; }

# --- RELOAD: the participant keeps running -------------------------------------------------
time_reload() {
  bash scripts/05-variant.sh v2 >/dev/null 2>&1 || return 1   # writes T0, then builds
  local t0; t0="$(cat logs/t0.source-write)"
  dpm script --dar artifacts/mirrors-seed-v1.dar --script-name Seed:cleanup \
    --ledger-host localhost --ledger-port 6865 -w >/dev/null 2>&1 || return 1
  POC_DAR=artifacts/mirrors-v2.dar console console/reload.canton 240 >/dev/null 2>&1 || return 1
  dpm script --dar artifacts/mirrors-seed.dar --script-name Seed:seed \
    --ledger-host localhost --ledger-port 6865 -w >/dev/null 2>&1 || return 1
  verify_seeded || return 1
  elapsed "$t0" "$(now)"
}

# --- RESTART: the supported path today ------------------------------------------------------
time_restart() {
  bash scripts/05-variant.sh v2 >/dev/null 2>&1 || return 1   # same T0 event
  local t0; t0="$(cat logs/t0.source-write)"
  bash scripts/00-sandbox.sh >/dev/null 2>&1 || return 1      # destroys parties and contracts
  POC_MODEL_DAR=artifacts/mirrors-v2.dar POC_SEED_DAR=artifacts/mirrors-seed.dar \
    bash scripts/10-seed.sh >/dev/null 2>&1 || return 1       # reallocates parties
  verify_seeded || return 1
  elapsed "$t0" "$(now)"
}

reload_times=(); restart_times=()
for i in $(seq 1 "$trials"); do
  tag="trial $i/$trials"; [ "$i" -eq 1 ] && tag="$tag (warm-up, discarded)"

  # if/else, not `a && b || c`: with the chained form a false warm-up guard falls through to the
  # `||` branch and prints FAILED next to a perfectly good measurement.
  reset_to_v1 || { echo "  $tag reload  RESET FAILED"; continue; }
  r="$(time_reload)" || r=""
  if [ -n "$r" ]; then
    echo "  $tag reload   ${r}s"
    if [ "$i" -gt 1 ]; then reload_times+=("$r"); fi
  else
    echo "  $tag reload   FAILED"
  fi

  reset_to_v1 || { echo "  $tag restart RESET FAILED"; continue; }
  s="$(time_restart)" || s=""
  if [ -n "$s" ]; then
    echo "  $tag restart  ${s}s"
    if [ "$i" -gt 1 ]; then restart_times+=("$s"); fi
  else
    echo "  $tag restart  FAILED"
  fi
done

banner "results"
python3 - "${#reload_times[@]}" "${reload_times[@]}" "${#restart_times[@]}" "${restart_times[@]}" <<'PY'
import sys, statistics as st
a = sys.argv[1:]
n1 = int(a[0]); rel = [float(x) for x in a[1:1+n1]]
n2 = int(a[1+n1]); res = [float(x) for x in a[2+n1:2+n1+n2]]
def line(name, xs):
    if not xs: print(f"{name:9s} no successful trials"); return None
    m = st.median(xs)
    print(f"{name:9s} n={len(xs):2d}  median={m:6.2f}s  min={min(xs):6.2f}s  max={max(xs):6.2f}s")
    return m
mr = line("reload", rel); ms = line("restart", res)
if mr and ms:
    print(f"\nreduction  {(ms-mr)/ms*100:.1f}%  (median restart {ms:.2f}s -> median reload {mr:.2f}s)")
    print("           conservative floor: excludes repairing anything holding the old party ids")
PY
echo
echo "#### LOG $log"
