#!/usr/bin/env bash
# LN7: ACS commitments after a coordinated reload on LocalNet (30-min ticks, interval enforced by the SV app).
# Fresh LocalNet + v1 fixture, reload v1 -> v2 (default timeouts), then wait past the next :00/:30 tick and
# list sent/received commitments on both app nodes. Also streams Splice circuit-breaker / faucet-trigger lines.
set -uo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/.." && pwd)"; Q="$R/.qs/quickstart"; M="$Q/docker/modules/localnet"; O="$R/logs/ln-ln7"; mkdir -p "$O"
(cd "$Q" && make clean-localnet >/dev/null 2>&1; make start-localnet LOCALNET_ONLY_RESOURCE_CONSTRAINTS="-f $M/resource-constraints.yaml -f $L/ln-logcap.yaml" > "$O/up.log" 2>&1)
rm -f "$L/state/fred.checkpoint"; cp "$R/variants/Shared.v1.daml" "$R/.gen-shared/v2/daml/Shared.daml"
"$L/ln-run.sh" ln-fixture.canton > "$O/fixture.out" 2>&1; V1=$(sed -n 's/^PKG V1=//p' "$O/fixture.out"); [ -n "$V1" ] || { echo "fixture failed"; exit 1; }
(docker logs -f --since 1s splice 2>&1 | grep --line-buffered -E 'CircuitBreaker|ReceiveFaucetCouponTrigger.*(Completed|Processing|"level":"(WARN|ERROR|INFO)")|SEQUENCER_BACKPRESSURE|"level":"(WARN|ERROR)"' > "$O/splice.filtered.log") &
echo "reload start $(date -u +%T)"; "$L/ln-run.sh" ln-timing-reload.canton -e LN_V1="$V1" > "$O/reload.out" 2>&1; grep -E '^(SEEDED|NOTE reload)' "$O/reload.out"; echo "reload end $(date -u +%T)"
# wait until 90s past the next half-hour tick
python3 - <<'PY'
import time; t=time.time(); nxt=(int(t)//1800+1)*1800+90; print(f"waiting {int(nxt-t)}s for tick"); time.sleep(nxt-t)
PY
sleep 1; pkill -f "docker logs -f --since 1s splice" 2>/dev/null
LN_SINCE_S=3600 "$L/ln-run.sh" ln-commit.canton > "$O/commit.out" 2>&1; grep -E '^NOTE' "$O/commit.out" | cut -c1-900
