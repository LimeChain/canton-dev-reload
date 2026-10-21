#!/usr/bin/env bash
# Multi-synchronizer row.
#
#   MS1  one participant connected to two synchronizers (`dpm sandbox --multi-sync`).
#        Vetting is per synchronizer, so the reload becomes one swap per synchronizer. The row
#        records what that changes: upload-with-vet needs a named synchronizer, the old package
#        stays usable on the unswapped synchronizer, and a contract left mid-reassignment is
#        stranded unless its reassignment is completed before archival.
#
# usage: 72-multisync.sh
#   POC_PREBUILT_DIR=<checkout>  reuse that checkout's artifacts/mirrors-v{1,2}.dar instead of
#                                building (for hosts where damlc cannot run); provenance-checked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

row="MS1"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="evidence/${stamp}__${row}__multisync.log"
mkdir -p evidence
exec > >(tee "$log") 2>&1

echo "#### ROW $row  (multi-synchronizer)"
echo

banner "setup: clean multi-synchronizer sandbox"
# Same shape as 00-sandbox.sh, but in Canton's bundled multi-synchronizer constellation.
pkill -f "canton-open-source.*jar sandbox" 2>/dev/null; sleep 3
: > logs/sandbox.log
nohup dpm sandbox --multi-sync --no-tty > logs/sandbox.log 2>&1 &
for i in $(seq 1 90); do
  grep -q "Canton sandbox is ready" logs/sandbox.log 2>/dev/null && break
  sleep 2
done
grep -q "Canton sandbox is ready" logs/sandbox.log || { echo "sandbox failed to start"; tail -20 logs/sandbox.log; exit 1; }
echo "sandbox ready, PID=$(sandbox_pid)  (multi-sync)"

rc=0
if [ -n "${POC_PREBUILT_DIR:-}" ]; then
  # damlc ships for x86_64 only, so a host without Rosetta cannot build. Reuse DARs the harness
  # built earlier, but only on proof: the source blob recorded at build time must equal the
  # committed source, and the console asserts Canton derives the recorded package id on upload.
  banner "setup: reuse prebuilt mirrors v1 (Text) and v2 (Int) from $POC_PREBUILT_DIR"
  for v in v1 v2; do
    cp "$POC_PREBUILT_DIR/artifacts/mirrors-$v.dar" artifacts/ || exit 1
    cp "$POC_PREBUILT_DIR/logs/variant-$v.provenance" logs/ || exit 1
    rec="$(sed -n 's/^mirrors_blob=//p' "logs/variant-$v.provenance")"
    now="$(git hash-object "variants/Mirrors.$v.daml")"
    if [ "$rec" = "$now" ]; then
      echo "ASSERT prebuilt-$v-source  PASS  built from committed blob $now"
    else
      echo "ASSERT prebuilt-$v-source  FAIL  built from $rec, committed source is $now"; rc=1
    fi
    sed -n 's/^mirrors_pkgid=//p' "logs/variant-$v.provenance" > "logs/pkgid-$v.txt"
  done
  [ "$rc" -eq 0 ] || { echo "FAIL prebuilt DARs do not match the committed sources"; exit 1; }
else
  banner "setup: build mirrors v1 (Text) and v2 (Int)"
  bash scripts/05-variant.sh v1 || exit 1
  bash scripts/05-variant.sh v2 || exit 1
fi

banner "MS1: reload across two synchronizers"
out="$(POC_V1_DAR=artifacts/mirrors-v1.dar POC_V2_DAR=artifacts/mirrors-v2.dar \
       POC_V1_PKG="$(cat logs/pkgid-v1.txt)" POC_V2_PKG="$(cat logs/pkgid-v2.txt)" \
       console console/multisync.canton 420 2>&1)"
console_rc=$?
printf '%s\n' "$out" | grep -E "^(SETUP|ASSERT|EXPECT_CODE|VERDICT)" || true

[ "$console_rc" -ne 0 ] && { echo "FAIL console exited $console_rc"; rc=1; }
printf '%s' "$out" | grep -q "^VERDICT PASS" || { echo "FAIL no VERDICT PASS from the console"; rc=1; }

banner "MS1: error codes behind each expected failure"
# The console only throws "Command execution failed."; the decoded code is in its error log.
while read -r _ step code; do
  if printf '%s' "$out" | grep -q "$code"; then
    printf 'ASSERT code-%-12s PASS  %s present in console output\n' "$step" "$code"
  else
    printf 'ASSERT code-%-12s FAIL  %s not found in console output\n' "$step" "$code"; rc=1
  fi
done < <(printf '%s\n' "$out" | grep "^EXPECT_CODE")
# One verbatim line per code, so the log carries the error text the proposal cites.
printf '%s\n' "$out" | grep -oE "GrpcRequestRefusedByServer: [A-Z_]+/[A-Z_]+\([0-9],[0-9a-f]+\): [^\\]{0,160}" \
  | awk '!seen[$2]++' | sed 's/^/VERBATIM /' || true

banner "provenance"
bash scripts/env-stamp.sh; stamp_rc=$?
# Any nonzero result voids: 1 = dirty/drifted, 2 = no reachable harness tag.
[ "$stamp_rc" -ne 0 ] && { echo "VOID provenance failed (env-stamp rc=$stamp_rc); cannot be cited"; rc=1; }

echo
echo "#### EXIT_CODE $rc"
[ "$rc" -eq 0 ] && echo "#### ROW $row PASS" || echo "#### ROW $row FAIL"
echo "#### LOG $log"
exit "$rc"
