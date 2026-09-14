#!/usr/bin/env bash
# Start the sandbox in the background on an OpenJDK (see lib.sh for why), wait for ready,
# and record the PID. The PID is a POC invariant: it must NOT change across a reload.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh
mkdir -p logs
pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 3
: > logs/sandbox.log
nohup dpm sandbox -c canton/sandbox.conf --no-tty > logs/sandbox.log 2>&1 &
for i in $(seq 1 40); do
  grep -q "Canton sandbox is ready" logs/sandbox.log 2>/dev/null && break
  sleep 2
done
grep -q "Canton sandbox is ready" logs/sandbox.log || { echo "sandbox failed to start"; tail -20 logs/sandbox.log; exit 1; }
pid="$(sandbox_pid)"
echo "SANDBOX_PID=$pid" > logs/sandbox.pid.txt
java -version 2>&1 | head -1 | sed 's/^/jvm: /'
echo "sandbox ready, PID=$pid  (ledger 6865 / json 6864 / admin 6866)"
