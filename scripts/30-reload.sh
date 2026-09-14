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
# Exit status carries the verdict. This used to be `console ... | grep -E "RELOAD" || exit 1`,
# which exits non-zero only when the string RELOAD is absent -- so a console that threw, or a
# swap that silently changed nothing, still presented as a passing row. Capture the output,
# propagate the real exit code, then filter for display.
reload_out="$(POC_DAR="$new_dar" console console/reload.canton 240 2>&1)"; reload_rc=$?
printf '%s\n' "$reload_out" | grep -E "RELOAD"
if [ "$reload_rc" -ne 0 ]; then
  echo "FAIL  reload exited $reload_rc"
  printf '%s\n' "$reload_out" | tail -20
  exit 1
fi

banner "3/3  reseed"
dpm script --dar artifacts/mirrors-seed.dar --script-name Seed:seed \
  --ledger-host localhost --ledger-port 6865 -w 2>&1 \
  | grep -E "MODEL|PARTY|SEED|SUCCESS|FAILURE" || true

pid_after="$(sandbox_pid)"
banner "invariants"
rc=0
if [ "$pid_before" = "$pid_after" ]; then echo "PASS  sandbox PID unchanged ($pid_after)"
else echo "FAIL  sandbox PID changed: $pid_before -> $pid_after"; rc=1; fi
if port_open 6865; then echo "PASS  ledger-api 6865 still open"
else echo "FAIL  ledger-api 6865 down"; rc=1; fi
# These invariants used to print FAIL and still exit 0, so a broken reload looked green to any
# caller checking the exit code.
exit "$rc"
