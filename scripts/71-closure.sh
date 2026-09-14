#!/usr/bin/env bash
# Multi-package (dependency closure) rows.
#
#   M1  rebuild items ONLY; leave holders and the client script at their v1 builds.
#       The dependent-not-rebuilt control: exercising the choice that fetches an Item must fail,
#       because the fetch needs the now-unvetted items v1.
#   M2  archive first, rebuild ALL THREE, swap both packages in ONE topology transaction,
#       reseed and peek with the v2 script. The closure loop end to end as a single operation --
#       which has never been run before; only the swap primitive and the failure mode had been.
#
# usage: 71-closure.sh M1|M2
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

row="${1:-}"
case "$row" in M1|M2) ;; *) echo "usage: 71-closure.sh M1|M2" >&2; exit 1 ;; esac

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="evidence/${stamp}__${row}__closure.log"
mkdir -p evidence
exec > >(tee "$log") 2>&1

script() {  # dar, script-name
  dpm script --dar "$1" --script-name "$2" --ledger-host localhost --ledger-port 6865 -w 2>&1
}

echo "#### ROW $row  (dependency closure)"
echo

banner "setup: clean sandbox, build closure at v1, upload VETTED, seed"
bash scripts/00-sandbox.sh || exit 1
bash scripts/06-variant-multi.sh v1 || exit 1
POC_DAR=artifacts/items-v1.dar   POC_VET=true console console/upload.canton 180 | grep -E "UPLOADED" || exit 1
POC_DAR=artifacts/holders-v1.dar POC_VET=true console console/upload.canton 180 | grep -E "UPLOADED" || exit 1
script artifacts/seedab-v1.dar SeedAB:seed | grep -E "SEEDAB|FAILURE" || true

banner "baseline: peek with the v1 script (cross-package fetch must work)"
base_out="$(script artifacts/seedab-v1.dar SeedAB:peek)"
printf '%s\n' "$base_out" | grep -oE "PEEK [^\\\\]*" || true
if ! printf '%s' "$base_out" | grep -q "PEEK holders=1"; then
  echo "FAIL baseline peek did not see the Holder"; exit 1
fi

rc=0
if [ "$row" = "M1" ]; then
  banner "M1: rebuild items ONLY to v2; holders and the client script stay at v1"
  bash scripts/06-variant-multi.sh v2 || exit 1
  echo "NOTE holders/seedab v2 DARs were built but are deliberately NOT uploaded here."

  banner "M1: swap items alone (adds=[newA] removes=[oldA]), no force flag"
  POC_A_DAR=artifacts/items-v2.dar POC_B_DAR="" console console/swap-closure.canton 240 \
    | grep -E "CLOSURE" || { echo "FAIL closure swap"; exit 1; }

  banner "M1: peek again with the v1 script -- the fetch must now fail"
  m1_out="$(script artifacts/seedab-v1.dar SeedAB:peek)"
  printf '%s\n' "$m1_out" | grep -oE "PEEK [^\\\\]*" || true
  printf '%s\n' "$m1_out" | grep -oE "PACKAGE_SELECTION_FAILED[^\\\\]*" | head -2 || true
  if printf '%s' "$m1_out" | grep -q "PACKAGE_SELECTION_FAILED"; then
    echo "ASSERT dependentFails PASS  exercising the fetch failed with PACKAGE_SELECTION_FAILED"
  else
    echo "ASSERT dependentFails FAIL  expected PACKAGE_SELECTION_FAILED, not found"; rc=1
  fi

else
  banner "M2: archive FIRST (dependents before dependencies: Holders, then Items)"
  script artifacts/seedab-v1.dar SeedAB:wipe | grep -E "WIPE" || true

  banner "M2: rebuild ALL THREE at v2"
  bash scripts/06-variant-multi.sh v2 || exit 1

  banner "M2: upload both unvetted and swap the closure in ONE transaction"
  POC_A_DAR=artifacts/items-v2.dar POC_B_DAR=artifacts/holders-v2.dar \
    console console/swap-closure.canton 240 | grep -E "CLOSURE" || { echo "FAIL closure swap"; exit 1; }

  banner "M2: reseed and peek with the v2 script"
  script artifacts/seedab-v2.dar SeedAB:seed | grep -E "SEEDAB|FAILURE" || true
  m2_out="$(script artifacts/seedab-v2.dar SeedAB:peek)"
  printf '%s\n' "$m2_out" | grep -oE "PEEK [^\\\\]*" || true
  if printf '%s' "$m2_out" | grep -q "PEEK holders=1"; then
    echo "ASSERT closureWorks  PASS  the rebuilt dependent fetched from the rebuilt dependency"
  else
    echo "ASSERT closureWorks  FAIL  peek did not see the Holder after the closure swap"; rc=1
  fi
  # The label is now an Int; seeing the Text literal back would mean the old code was still live.
  if printf '%s' "$m2_out" | grep -q "PEEK label=1"; then
    echo "ASSERT newTypeLive   PASS  label came back as the Int 1"
  else
    echo "ASSERT newTypeLive   FAIL  expected 'PEEK label=1' from the Int variant"; rc=1
  fi
fi

banner "provenance"
bash scripts/env-stamp.sh; stamp_rc=$?
[ "$stamp_rc" -eq 1 ] && { echo "VOID provenance assertions failed"; rc=1; }

echo
echo "#### EXIT_CODE $rc"
[ "$rc" -eq 0 ] && echo "#### ROW $row PASS" || echo "#### ROW $row FAIL"
echo "#### LOG $log"
exit "$rc"
