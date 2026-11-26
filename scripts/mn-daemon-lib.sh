#!/usr/bin/env bash
# Helpers for rows whose nodes must outlive a console: MN6 (crash) and PQS-P (PQS stays attached).
# Source after scripts/lib.sh with TAG set. Nodes run in one daemon (multinode.conf, bootstrap
# mn-lib + mn-daemon); each "Fred" step is a separate remote console (multinode-remote.conf + mn-rlib).
JAR="$HOME/.dpm/cache/components/canton-open-source/3.5.12/lib/canton-open-source-3.5.12.jar"
: "${TAG:?TAG must be set}"
D_DIR="$ROOT/logs/$TAG"; mkdir -p "$D_DIR"
export MN_V1_DAR="$ROOT/artifacts/shared-v1.dar" MN_V2_DAR="$ROOT/artifacts/shared-v2.dar"
export MN_H2_DIR="$D_DIR/h2" MN_CKPT="$D_DIR/fred.checkpoint"
DAEMON_PID=""; CN=0

mn_daemon_start() {
  pkill -f "canton-open-source-3.5.12.jar (daemon|run)" 2>/dev/null; sleep 2
  rm -rf "$MN_H2_DIR" "$MN_CKPT"; mkdir -p "$MN_H2_DIR"
  cat console/mn-lib.canton "${MN_DAEMON_FIXTURE:-console/mn-daemon.canton}" > "$D_DIR/daemon.canton"
  : > "$D_DIR/daemon.canton.log"
  java -jar "$JAR" daemon -c canton/multinode.conf --bootstrap "$D_DIR/daemon.canton" \
    --log-file-name "$D_DIR/daemon.canton.log" > "$D_DIR/daemon.out" 2>&1 < /dev/null &
  DAEMON_PID=$!
  for _ in $(seq 1 180); do
    grep -q "^MN READY" "$D_DIR/daemon.out" && break
    kill -0 "$DAEMON_PID" 2>/dev/null || { echo "daemon died, see $D_DIR/daemon.out"; tail -20 "$D_DIR/daemon.out"; return 1; }
    sleep 1
  done
  grep -q "^MN READY" "$D_DIR/daemon.out" || { echo "daemon not ready in 180s"; return 1; }
  export MN_V1_PKG="$(sed -n 's/^PKG V1=//p' "$D_DIR/daemon.out")" MN_V2_PKG="$(sed -n 's/^PKG V2=//p' "$D_DIR/daemon.out")"
  echo "daemon ready pid=$DAEMON_PID V1=${MN_V1_PKG:0:12} V2=${MN_V2_PKG:0:12}"
}
mn_daemon_stop() { [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null; sleep 3; kill -9 "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""; }

# rcon <name> <script> : remote console, foreground; output in $D_DIR/NN-<name>.out, Canton log beside it.
# rcon_bg <name> <script> : same, in the background; sets RCON_PID.
_rcon_prep() { CN=$((CN+1)); RNAME="$(printf '%02d-%s' "$CN" "$1")"
  cat console/mn-rlib.canton "$2" > "$D_DIR/$RNAME.canton"; : > "$D_DIR/$RNAME.canton.log"; }
_rcon_cmd() { java -jar "$JAR" run "$D_DIR/$RNAME.canton" -c canton/multinode-remote.conf \
  --log-file-name "$D_DIR/$RNAME.canton.log" > "$D_DIR/$RNAME.out" 2>&1 < /dev/null; }
rcon() { _rcon_prep "$1" "$2"; with_timeout "${RCON_TIMEOUT:-400}" _rcon_cmd; local r=$?
  grep -E "^(SETUP|NOTE|ASSERT|EXPECT_|VERDICT|TIME|CKPT|T )" "$D_DIR/$RNAME.out"
  grep -q "^VERDICT PASS" "$D_DIR/$RNAME.out" || { echo "console $RNAME: no VERDICT PASS (rc=$r), see $D_DIR/$RNAME.out"; grep -A3 -E "\.canton:[0-9]+:|Script execution failed" "$D_DIR/$RNAME.out" | head -12; return 1; }
  codes "$D_DIR/$RNAME.out"; }
rcon_bg() { _rcon_prep "$1" "$2"; _rcon_cmd & RCON_PID=$!; }

# Decoded codes: in this console's Canton log or the daemon's (node-side errors land there).
has_code() { grep -qE "$1\([0-9]+,[0-9a-f]+\)|code = '$1'" "$D_DIR/$RNAME.canton.log" "$D_DIR/daemon.canton.log" 2>/dev/null; }
codes() { local r=0
  while read -r _ step code; do if has_code "$code"; then printf 'ASSERT code-%-14s PASS  %s present\n' "$step" "$code"
    else printf 'ASSERT code-%-14s FAIL  %s not found\n' "$step" "$code"; r=1; fi; done < <(grep "^EXPECT_CODE" "$1")
  while read -r _ step code; do if has_code "$code"; then printf 'ASSERT nocode-%-12s FAIL  %s present\n' "$step" "$code"; r=1
    else printf 'ASSERT nocode-%-12s PASS  %s absent\n' "$step" "$code"; fi; done < <(grep "^EXPECT_NO_CODE" "$1")
  return $r; }
