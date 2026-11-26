#!/usr/bin/env bash
# ln-restart.sh <label> : time the LocalNet restart path = clean-localnet + start-localnet + seed (parties,
# rights, upload+vet v1, seed) until the seed console's verdict. Prints TIME lines (seconds).
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; Q="$D/../.qs/quickstart"; L="$1"; O="$D/state/restart-$L.out"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
t0=$(ms); (cd "$Q" && make clean-localnet >/dev/null 2>&1); t1=$(ms)
(cd "$Q" && make start-localnet >/dev/null 2>&1); t2=$(ms)
rm -f "$D/state/fred.checkpoint"; "$D/ln-run.sh" ln-seed-v1.canton > "$O" 2>&1; t3=$(ms)
v=$(grep -E '^VERDICT' "$O" | tail -1)
printf 'TIME %s stop=%.1f start=%.1f setup=%.1f total=%.1f %s\n' "$L" $(echo "($t1-$t0)/1000;($t2-$t1)/1000;($t3-$t2)/1000;($t3-$t0)/1000" | bc -l | tr '\n' ' ') "$v"
