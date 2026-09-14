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
