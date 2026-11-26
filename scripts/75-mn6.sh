#!/usr/bin/env bash
# MN6 (Q7): kill -9 "Fred" while the synchronizers are quiesced (rate 0), before any purge; a fresh
# console must restore the rates from the checkpoint and the reload must then complete.
# EXPLORATORY until committed and tagged; output under logs/mn6/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh
TAG=mn6; . scripts/mn-daemon-lib.sh
rc=0
mn_daemon_start || exit 1

banner "MN6.1 arm: quiesce, then hang"
rcon_bg arm console/mn6-arm.canton
for _ in $(seq 1 120); do grep -q "^ARMED" "$D_DIR/$RNAME.out" && break; sleep 1; done
grep -E "^(ASSERT|CKPT|ARMED)" "$D_DIR/$RNAME.out"
grep -q "^ARMED" "$D_DIR/$RNAME.out" || { echo "FAIL arm console never armed"; mn_daemon_stop; exit 1; }
kill -9 "$RCON_PID"; wait "$RCON_PID" 2>/dev/null
echo "KILLED arm console pid=$RCON_PID with SIGKILL"
kill -0 "$DAEMON_PID" 2>/dev/null && echo "daemon still running" || { echo "FAIL daemon died"; exit 1; }

banner "MN6.2 observe what the crash left"
rcon observe console/mn6-observe.canton || rc=1
banner "MN6.3 resume from the checkpoint, then complete the reload"
RCON_TIMEOUT=500 rcon resume console/mn6-resume.canton || rc=1
mn_daemon_stop
echo "MN6 rc=$rc"
exit $rc
