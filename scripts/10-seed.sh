#!/usr/bin/env bash
# Upload the current mirrors DAR (vetted) and run the seed script.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

banner "UPLOAD mirrors (vetted)"
POC_DAR="${POC_MODEL_DAR:-artifacts/mirrors.dar}" POC_VET=true console console/upload.canton 180 \
  | grep -E "UPLOADED|^DAR |VETTED_CONTAINS_MAIN|ERROR" || true

banner "RUN seed script"
dpm script \
  --dar "${POC_SEED_DAR:-artifacts/mirrors-seed.dar}" \
  --script-name Seed:seed \
  --ledger-host localhost --ledger-port 6865 \
  -w 2>&1 | grep -viE "^\s*$" | tail -20

banner "RECORD party ids"
console console/parties.canton 180 2>&1 | grep "^PARTYVAR " | sed 's/^PARTYVAR //' > logs/parties.env
cat logs/parties.env

# This script used to end on `cat`, which succeeds even on an empty file -- so it always exited 0
# and every caller's `|| { echo "FAIL seed"; exit 1; }` was dead code. A failed seed then carried on
# silently, and 80-timing.sh would time a trial against an unseeded ledger and blame the wrong step.
if [ ! -s logs/parties.env ]; then
  echo "FAIL  seed produced no party ids -- upload or seed script failed above" >&2
  exit 1
fi
