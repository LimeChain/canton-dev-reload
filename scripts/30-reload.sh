#!/usr/bin/env bash
# One-command reload: rebuild -> upload unvetted -> atomic vetting swap -> reseed.
# The sandbox process, its ports, and all party IDs survive untouched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

variant="${1:-v2}"
pid_before="$(sandbox_pid)"

banner "1/3  rebuild ($variant)"
bash scripts/05-variant.sh "$variant" || exit 1
new_dar="artifacts/mirrors-$variant.dar"

banner "2/3  reload (upload unvetted + atomic vetting swap)"
POC_DAR="$new_dar" console console/reload.canton 240 2>&1 \
  | grep -E "RELOAD" || { echo "reload failed"; exit 1; }

banner "3/3  reseed"
dpm script --dar artifacts/mirrors-seed.dar --script-name Seed:seed \
  --ledger-host localhost --ledger-port 6865 -w 2>&1 \
  | grep -E "MODEL|PARTY|SEED|SUCCESS|FAILURE" || true

pid_after="$(sandbox_pid)"
banner "invariants"
[ "$pid_before" = "$pid_after" ] && echo "PASS  sandbox PID unchanged ($pid_after)" \
                                || echo "FAIL  sandbox PID changed: $pid_before -> $pid_after"
port_open 6865 && echo "PASS  ledger-api 6865 still open" || echo "FAIL  ledger-api 6865 down"
