#!/usr/bin/env bash
# FRED reload + PQS prune on a running CN QuickStart LocalNet (OAuth2, two single-party PQS
# instances). Per participant: g1 (2 contracts) -> archive -> record O_after -> swap to g2
# (2 contracts) -> wait for that participant's PQS -> dry run + prune its own database to O_after.
# Every console call and SQL call gets its own numbered log; results go to measures.tsv.
set -uo pipefail
export LC_ALL=C
D="$(cd "$(dirname "$0")" && pwd)"; QS="${QS_DIR:?QS_DIR must point at a cn-quickstart checkout's quickstart/ directory}"; FIX="$D/../fixtures"
LOGDIR="${PQS_LOGROOT:-$D/logs}/Q"; mkdir -p "$LOGDIR"; [ -n "${KEEP_LOGS:-}" ] || { : > "$LOGDIR/measures.tsv"; : > "$LOGDIR/steps.tsv"; }; N=${N0:-0}
G1=$(awk -F'\t' '$1=="A-g1"{print $4}' "$FIX/fixtures.tsv"); G2=$(awk -F'\t' '$1=="A-g2"{print $4}' "$FIX/fixtures.tsv")
M="mirrors:Mirrors:Mirror"
die() { echo "STOP $*" | tee -a "$LOGDIR/steps.tsv" >&2; exit 1; }
measure() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LOGDIR/measures.tsv"; }
nextlog() { N=$((N+1)); LOG="$(printf '%s/%02d-%s.log' "$LOGDIR" "$N" "$1")"; }

# QuickStart's own console service, with this directory and the fixtures mounted.
# The Makefile exports these for compose; reproduce them.
export MODULES_DIR="$QS/docker/modules" LOCALNET_DIR="$QS/docker/modules/localnet" IMAGE_TAG="$(sed -n 's/^SPLICE_VERSION=//p' "$QS/.env")"
read -r -a COMPOSE <<< "$(cd "$QS" && TEST_PORT= make -n canton-console 2>/dev/null | tail -1 | sed 's/ run --rm --name canton-console console$//')"
con() {  # name P PHASE [KEY=VAL...]
  local name="$1" p="$2" phase="$3"; shift 3; local -a e=(-e "P=$p" -e "PHASE=$phase" -e "PARTY=$(party_of "$p")")
  local kv; for kv in "$@"; do e+=(-e "$kv"); done
  local tp tu; tp=$(token PROVIDER); tu=$(token USER)
  local mine; [ "$p" = app-provider ] && mine="$tp" || mine="$tu"
  e+=(-e "FRED_PROVIDER_TOKEN=$tp" -e "FRED_USER_TOKEN=$tu" -e "LEDGER_USER=$(sub_of "$mine")")
  nextlog "$name"; local log="$LOG"
  (cd "$QS" && TEST_PORT= "${COMPOSE[@]}" run --rm -T -v "$D:/fred" -v "$FIX:/fix" --entrypoint /fred/entry.sh "${e[@]}" console) > "$log" 2>&1
  local rc=$?; printf '%s\t%s\trc=%s\t%s\n' "$N" "$name" "$rc" "$(basename "$log")" >> "$LOGDIR/steps.tsv"
  LAST_LOG="$log"; [ $rc -eq 0 ] || die "console $name rc=$rc, see $log"
}
# A Keycloak token for a participant's validator user (client credentials, QuickStart's dev defaults).
token() { docker exec -e P="$1" splice-onboarding sh -c 'eval id=\$AUTH_APP_${P}_VALIDATOR_CLIENT_ID sec=\$AUTH_APP_${P}_VALIDATOR_CLIENT_SECRET url=\$AUTH_APP_${P}_TOKEN_URL
  curl -sf -d grant_type=client_credentials -d client_id=$id -d client_secret=$sec -d scope=openid "$url"' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'; }
sub_of() { python3 -c 'import sys,json,base64;t=sys.argv[1].split(".")[1];print(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4)))["sub"])' "$1"; }
tval() { sed -n "s/^T $1=//p" "$LAST_LOG" | tail -1; }
_sql() { docker exec postgres psql -v ON_ERROR_STOP=1 -U cnadmin -d "$1" -tA -F' | ' -c "$2"; }
sql() {  # name db sql : logged, must succeed; sets VAL to the last line
  nextlog "$1"; _sql "$2" "$3" > "$LOG" 2>&1; local rc=$?
  printf '%s\t%s\trc=%s\t%s\n' "$N" "$1" "$rc" "$(basename "$LOG")" >> "$LOGDIR/steps.tsv"
  [ $rc -eq 0 ] || die "sql $1 rc=$rc, see $LOG"; VAL="$(grep -v '^NOTICE' "$LOG" | tail -1)"
}
mv_() { sql "$3" "$4" "$5"; measure "$1" "$2" "$VAL"; }
wait_pqs() {  # db offset
  for _ in $(seq 1 120); do
    local cp; cp=$(_sql "$1" "select (latest_checkpoint()).offset" 2>/dev/null | tail -1)
    [ -n "$cp" ] && [ "$cp" -ge "$2" ] 2>/dev/null && { printf -- '-\twait-%s-%s\tcheckpoint=%s\n' "$1" "$2" "$cp" >> "$LOGDIR/steps.tsv"; return 0; }
    sleep 1
  done; die "$1 did not reach $2"
}
counts() {  # tag db
  mv_ "$1" retired_creates "$1-retired" "$2" "select count(*) from creates('$M') where package_id <> '$G2'"
  mv_ "$1" current_active  "$1-current" "$2" "select count(*) from active('$M') where package_id = '$G2'"
  mv_ "$1" all_items_rows  "$1-total-creates" "$2" "select count(*) from creates()"
}

# The party each PQS reads as, from its own startup line; its database is pqs-<participant>.
party_of() { docker logs "pqs-$1" 2>&1 | grep -m1 -oE "on behalf of '[^']*'" | sed -E "s/on behalf of '(.*)'/\1/"; }
for p in app-provider app-user; do
  c="pqs-$p"; pp=$(party_of "$p")
  [ -n "$pp" ] || die "no party for $c"
  measure "$p" pqs_reads_as "${pp%%::*}"
  measure "$p" pqs_restarts_before "$(docker inspect -f '{{.RestartCount}}' "$c")"
done

# PARTS selects the participants (default both), so one side can be rerun on its own.
for p in ${PARTS:-app-provider app-user}; do
  db="pqs-$p"
  con "$p-init" "$p" init DAR=/fix/A-g1.dar; [ "$(tval G1)" = "$G1" ] || die "g1 id"
  measure "$p" synchronizers "$(tval SYNCS)"; wait_pqs "$db" "$(tval LASTTX)"
  mv_ "$p-g1" g1_rows "$p-g1-rows" "$db" "select count(*) from active('$M') where package_id = '$G1'"
  con "$p-archive" "$p" archive PKG=$G1; OA=$(tval END); measure "$p" O_after "$OA"
  con "$p-swap" "$p" swap OLD=$G1 NEW_DAR=/fix/A-g2.dar TY=Int; [ "$(tval NEW)" = "$G2" ] || die "g2 id"
  wait_pqs "$db" "$(tval LASTTX)"
  counts "$p-before-prune" "$db"
  t0=$(python3 -c 'import time;print(time.time())')
  sql "$p-prune-dry" "$db" "select * from prune_archived_to_offset_dry_run($OA)"
  sql "$p-prune" "$db" "select * from prune_archived_to_offset($OA)"
  measure "$p" prune_seconds "$(python3 -c "import time;print(round(time.time()-$t0,3))")"
  counts "$p-after-prune" "$db"
  measure "$p" pqs_restarts_after "$(docker inspect -f '{{.RestartCount}}' "pqs-$p")"
  measure "$p" pqs_status_after "$(docker inspect -f '{{.State.Status}}' "pqs-$p")"
done
# Party isolation: each PQS database holds only its own participant's mirrors.
for p in app-provider app-user; do
  mv_ isolation "$p-mirror-creates" "iso-$p" "pqs-$p" "select count(*) from creates('$M')"
done
echo "RUN COMPLETE"
