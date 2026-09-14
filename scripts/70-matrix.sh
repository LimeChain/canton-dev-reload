#!/usr/bin/env bash
# Run one row of the force-flag matrix from a CLEAN sandbox, capture a stamped evidence log, and
# exit with the row's verdict.
#
# Every row starts from a fresh sandbox process. With storage = memory that is a true clean
# slate, which is the cheapest reset available -- and skipping it is what produced the original
# chained-state problem, where an "atomic swap" row actually ran against an already-unvetted v1.
#
# usage: 70-matrix.sh <ROW>       ROW in C1 C2 E1 E2 E3 E4 E5
#        70-matrix.sh E6          shorthand for three independent clean-sandbox repeats of E1
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

row="${1:-}"

# ---- per-row contract ----------------------------------------------------------------------
# op | force | state | expect | expect_err | v1Vetted | v2Vetted | serialDelta | acs | onV1
case "$row" in
  C1) op=add-second; force=none;                  state=live;     expect=fail;    err=KNOWN_PACKAGE_VERSION; xv1=true;  xv2=false; xd=0; xacs=2; xon=2 ;;
  C2) op=add-second; force=allow-vet-incompatible; state=live;    expect=succeed; err="";                    xv1=true;  xv2=true;  xd=1; xacs=2; xon=2 ;;
  E1) op=swap;       force=none;                  state=archived; expect=succeed; err="";                    xv1=false; xv2=true;  xd=1; xacs=0; xon=0 ;;
  E2) op=swap;       force=none;                  state=live;     expect=succeed; err="";                    xv1=false; xv2=true;  xd=1; xacs=2; xon=2 ;;
  E3) op=swap;       force=allow-vet-incompatible; state=archived; expect=succeed; err="";                   xv1=false; xv2=true;  xd=1; xacs=0; xon=0 ;;
  E4) op=unvet;      force=none;                  state=live;     expect=succeed; err="";                    xv1=false; xv2=false; xd=1; xacs=2; xon=2 ;;
  E5) op=unvet;      force=allow-vet-incompatible; state=live;    expect=succeed; err="";                    xv1=false; xv2=false; xd=1; xacs=2; xon=2 ;;
  E6)
    # Determinism: three INDEPENDENT clean-sandbox repeats of E1, not three operations against
    # one sandbox.
    rc=0
    for i in 1 2 3; do
      banner "E6 repeat $i/3 (independent clean sandbox)"
      POC_ROW_LABEL="E6r$i" bash scripts/70-matrix.sh E1 || rc=1
    done
    exit "$rc"
    ;;
  *) echo "usage: 70-matrix.sh C1|C2|E1|E2|E3|E4|E5|E6" >&2; exit 1 ;;
esac

label="${POC_ROW_LABEL:-$row}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="evidence/${stamp}__${label}__${op}__force-${force}__${state}.log"
mkdir -p evidence

# Everything from here lands in the evidence file AND on the terminal.
exec > >(tee "$log") 2>&1

echo "#### ROW $label  op=$op force=$force state=$state"
echo "#### EXPECT result=$expect err='${err}' v1Vetted=$xv1 v2Vetted=$xv2 serialDelta=$xd acs=$xacs onV1=$xon"
echo

banner "setup: clean sandbox"
bash scripts/00-sandbox.sh || exit 1

banner "setup: build v1 (Text) and seed"
bash scripts/05-variant.sh v1 || exit 1
# The seed script is compiled against the model, so keep the v1-built copy: archiving v1-shaped
# contracts needs the v1-shaped script, and the v2 build below overwrites mirrors-seed.dar.
cp artifacts/mirrors-seed.dar artifacts/mirrors-seed-v1.dar
POC_MODEL_DAR=artifacts/mirrors-v1.dar POC_SEED_DAR=artifacts/mirrors-seed-v1.dar \
  bash scripts/10-seed.sh >/dev/null 2>&1 || { echo "FAIL seed"; exit 1; }

banner "setup: build v2 (Int), upload UNVETTED"
bash scripts/05-variant.sh v2 || exit 1
POC_DAR=artifacts/mirrors-v2.dar POC_VET=false console console/upload.canton 180 \
  | grep -E "UPLOADED|VETTED_CONTAINS_MAIN" || { echo "FAIL upload v2"; exit 1; }

if [ "$state" = "archived" ]; then
  banner "setup: archive v1 contracts (the only window in which this is possible)"
  dpm script --dar artifacts/mirrors-seed-v1.dar --script-name Seed:cleanup \
    --ledger-host localhost --ledger-port 6865 -w 2>&1 | grep -oE "CLEANUP [^\\]*" || true
fi

banner "provenance"
bash scripts/env-stamp.sh; stamp_rc=$?
# rc 2 means the harness tag does not exist yet: the run is reproducible but not evidence-grade.
# rc 1 means provenance FAILED -- a dirty tree or a drifted harness -- and must void the row.
if [ "$stamp_rc" -eq 1 ]; then
  echo "VOID  provenance assertions failed; this row cannot be cited"
  exit 1
fi

banner "operation"
V1ID="$(cat logs/pkgid-v1.txt)"; V2ID="$(cat logs/pkgid-v2.txt)"
# The participant log is rotated daily, so it accumulates across rows. Count the oracle line
# BEFORE the operation and report the delta, otherwise every row after the first inherits
# earlier rows' hits and the oracle says nothing about this row.
oracle_pre=$(grep -c "AllowVetIncompatibleUpgrades is set" log/canton.log 2>/dev/null || true)
oracle_pre=${oracle_pre:-0}
op_out="$(POC_V1="$V1ID" POC_V2="$V2ID" \
POC_OP="$op" POC_FORCE="$force" \
POC_EXPECT="$expect" POC_EXPECT_ERR="$err" \
POC_EXPECT_V1="$xv1" POC_EXPECT_V2="$xv2" \
POC_EXPECT_DELTA="$xd" POC_EXPECT_ACS="$xacs" POC_EXPECT_ON_V1="$xon" \
  console console/one-op.canton 240 2>&1)"
op_rc=$?
printf '%s\n' "$op_out"

# The error-code assertion lives here rather than in the console script: Canton throws a generic
# "Command execution failed." and logs the decoded error separately, so the code is only visible
# in the captured output. This is also the verbatim string the proposal quotes.
if [ "$expect" = "fail" ] && [ -n "$err" ]; then
  if printf '%s' "$op_out" | grep -q "$err"; then
    echo "ASSERT errorCode      PASS got=$err want=$err"
  else
    echo "ASSERT errorCode      FAIL expected '$err' in console output, not found"
    op_rc=1
  fi
fi

# The oracle: presence of this line in the participant log proves the flag reached Canton.
# We expected it to be silent on `unvet` rows (adds = []). It is not -- E5 showed it firing with
# "newly-added packages Set()", i.e. the flag is applied and simply has nothing to validate. So
# the oracle is usable on EVERY row, which is what makes E4's zero lines independent evidence
# that the unvet row genuinely ran unforced.
banner "force-flag oracle (participant log)"
oracle_post=$(grep -c "AllowVetIncompatibleUpgrades is set" log/canton.log 2>/dev/null || true)
oracle_post=${oracle_post:-0}
oracle_delta=$(( oracle_post - oracle_pre ))
echo "oracle_lines_this_row   $oracle_delta   (before=$oracle_pre after=$oracle_post)"
if [ "$force" = "allow-vet-incompatible" ]; then
  echo "oracle_interpretation   expect >0 (flag was passed). On an unvet row the line"
  echo "                        still fires, logging 'newly-added packages Set()' -- the flag"
  echo "                        is applied but has nothing to validate, which is why E4==E5."
  [ "$oracle_delta" -gt 0 ] && echo "oracle_verdict          CONSISTENT" || echo "oracle_verdict          INCONSISTENT - flag requested but Canton did not log it"
else
  echo "oracle_interpretation   expect 0 (no flag passed)"
  [ "$oracle_delta" -eq 0 ] && echo "oracle_verdict          CONSISTENT" || echo "oracle_verdict          INCONSISTENT - no flag requested but Canton logged one"
fi

echo
echo "#### EXIT_CODE $op_rc"
[ "$op_rc" -eq 0 ] && echo "#### ROW $label PASS" || echo "#### ROW $label FAIL"
echo "#### LOG $log"
exit "$op_rc"
