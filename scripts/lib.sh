#!/usr/bin/env bash
# Shared helpers for the dev-model-reload POC.
set -uo pipefail

# zsh-safe: BASH_SOURCE only exists under bash. Scripts are run with bash, but this file
# is also sourced ad hoc, so fall back to POC_ROOT / $PWD.
if [ -n "${BASH_SOURCE:-}" ]; then _lib_self="${BASH_SOURCE[0]}"; else _lib_self="${0:-}"; fi
ROOT="${POC_ROOT:-}"
if [ -z "$ROOT" ] && [ -n "$_lib_self" ] && [ -f "$_lib_self" ]; then
  ROOT="$(cd "$(dirname "$_lib_self")/.." && pwd)"
fi
[ -z "$ROOT" ] && ROOT="$PWD"

# --- JDK selection (POC-local; your global environment is untouched) -------------------
# Canton's fat jar bundles BouncyCastle UNSHADED and UNSIGNED. Oracle JDKs enforce JCE
# provider jar signing, so every transaction submit dies with
#   SecurityException: JCE cannot authenticate the provider BC
# surfacing to the client as an opaque INTERNAL error. OpenJDK builds do not enforce this.
# Verified: Oracle 17.0.7 FAIL, Oracle 18.0.2 FAIL, OpenJDK 21.0.12.1 OK.
for _jdk in /opt/homebrew/opt/openjdk@21 /opt/homebrew/opt/openjdk \
            /usr/local/opt/openjdk@21 /usr/local/opt/openjdk \
            /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-21-openjdk; do
  if [ -x "$_jdk/bin/java" ]; then
    export JAVA_HOME="$_jdk"
    export PATH="$_jdk/bin:$PATH"
    break
  fi
done
# If none matched we fall through to whatever `java` is on PATH -- which is exactly the failure this
# block exists to prevent, so say so loudly rather than silently. An Oracle JDK here means every
# transaction submit dies with an opaque INTERNAL.
if ! java -version 2>&1 | grep -qi "openjdk"; then
  echo "WARNING: no OpenJDK found (searched Homebrew and /usr/lib/jvm). Running on:" >&2
  java -version 2>&1 | head -1 | sed 's/^/         /' >&2
  echo "         On an Oracle JDK every Daml transaction will fail with an opaque INTERNAL." >&2
fi
LOGS="$ROOT/logs"
# Both are gitignored, so a fresh clone has neither. Every driver's first real action builds into
# artifacts/, so without this a clean checkout fails on its first command.
mkdir -p "$LOGS" "$ROOT/artifacts"

# The Canton console runs a Scala 2.13 compiler. `import scala.util.{Try, ...}` makes it read
# scala/util/*.tasty out of the Canton fat jar and fail with "Add -Ytasty-reader to scalac options".
# Every console script in this repo therefore uses fully-qualified `scala.util.Try` instead.

# macOS has no coreutils `timeout`; the Canton console can hang on a failed bootstrap,
# so every console invocation gets a hard watchdog.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  # The watchdog MUST NOT inherit stdout/stderr. If it does, it holds the write end of
  # any pipe (`| grep`) or command substitution (`$(...)`) the caller set up, and the
  # shell then blocks until the watchdog's `sleep` finishes -- even though the real
  # command already exited. That turned a 4s console call into a full-timeout wait and
  # made the whole reload appear to take minutes.
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null & local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

# Run a Canton console bootstrap script against the running sandbox.
# The repair feature gate is CONSOLE-side (FeatureFlagFilter reads consoleEnvironment),
# so it must be supplied here, not to the sandbox process.
console() {
  local script="$1"; local secs="${2:-240}"
  # TWO distinct console gates are needed for the full loop:
  #   enable-repair-commands  -> repair.purge   (FeatureFlag.Repair)
  #   enable-preview-commands -> dars.remove    (FeatureFlag.Preview)
  # enable-testing-commands does NOT unlock dars.remove.
  with_timeout "$secs" dpm canton-console \
    -C canton.features.enable-repair-commands=yes \
    -C canton.features.enable-preview-commands=yes \
    --bootstrap "$script" --no-tty < /dev/null
}

sandbox_pid() { pgrep -f "canton-open-source.*jar sandbox" | head -1; }

port_open() { nc -z localhost "$1" >/dev/null 2>&1; }

banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
