#!/usr/bin/env bash
# THE PRESENTATION. Four acts:
#   ACT 1  today it breaks    -- Canton rejects the rebuilt package
#   ACT 2  so you restart     -- and lose every party and contract
#   ACT 3  reload, wrong order -- works, but strands contracts you cannot even archive
#   ACT 4  reload, right order -- archive first: nothing stranded, old package removed
#
#   bash scripts/60-story.sh --live   # YOU hand-edit the .daml file (recommended)
#   bash scripts/60-story.sh          # script swaps the variant for you
#   ... add --no-pause to run straight through (rehearsal only; not with --live)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

live=0; nopause=0
for a in "$@"; do
  case "$a" in
    --live) live=1 ;;
    --no-pause) nopause=1 ;;
    *) echo "usage: 60-story.sh [--live] [--no-pause]"; exit 1 ;;
  esac
done

pause() { [ "$nopause" = 1 ] || { printf '\n\033[2m   ── press Enter ──\033[0m'; read -r _ </dev/tty; echo; }; }
act()   { printf '\n\n\033[1;44m  %s  \033[0m\n\n' "$1"; }
say()   { printf '   \033[2m%s\033[0m\n' "$1"; }
hit()   { printf '   \033[1m%b\033[0m\n' "$1"; }
bad()   { printf '   \033[1;31m%b\033[0m\n' "$1"; }
good()  { printf '   \033[1;32m%b\033[0m\n' "$1"; }
warn()  { printf '   \033[1;33m%b\033[0m\n' "$1"; }
sh_()   { local v="$1"; [ ${#v} -gt 30 ] && echo "${v:0:30}.." || echo "$v"; }

facts()  { console console/assert.canton 200 2>/dev/null | grep '^ASSERT|'; }
p_alice(){ printf '%s\n' "$1" | awk -F'|' '$2=="party" && $3=="Alice"{print $4; exit}'; }
p_count(){ printf '%s\n' "$1" | awk -F'|' '$2=="acs"{s+=$6} END{print s+0}'; }
p_live() { printf '%s\n' "$1" | awk -F'|' '$2=="dar" && $6=="LIVE"{print $5; exit}'; }

SRC=mirrors/daml/Mirrors.daml

# ---------------------------------------------------------------- setup
act "SETUP  a running ledger with the current model and some data"
# (variant selection belongs to 05-variant.sh, which builds from a generated project)
bash scripts/00-sandbox.sh    || exit 1
bash scripts/05-variant.sh v1 >/dev/null 2>&1
cp artifacts/mirrors-seed.dar artifacts/mirrors-seed-v1.dar
bash scripts/10-seed.sh       >/dev/null 2>&1
F=$(facts); A1=$(p_alice "$F"); PID1=$(sandbox_pid); V1=$(cat logs/pkgid-v1.txt)
hit "Alice       $(sh_ "$A1")"
hit "contracts   $(p_count "$F")     PID $PID1"
hit "model       mirrors 1.0.0  $(echo "$V1" | cut -c1-12)..   (value : Text)"
say "A developer's working environment: parties allocated, test data created,"
say "an app connected. Everything below is about not losing it."
pause

# ---------------------------------------------------------------- act 1
act "ACT 1  you change one line and rebuild.  Canton says no."
if [ "$live" = 1 ]; then
  hit "Now edit  $SRC  in your editor:"
  printf '\n      \033[1;36mtype Val = Text\033[0m   ->   \033[1;36mtype Val = Int\033[0m\n\n'
  say "(line 12 -- that is the whole change. Save the file.)"
  while : ; do
    printf '\033[2m   ── save the file, then press Enter ──\033[0m'; read -r _ </dev/tty; echo
    bash scripts/05-variant.sh live >/dev/null 2>&1
    NEW=$(cat logs/pkgid-live.txt)
    [ "$NEW" != "$V1" ] && break
    warn "The rebuilt package hash is unchanged -- the file was not saved, or not edited yet."
  done
  NEWDAR=artifacts/mirrors-live.dar; TARGET=live
else
  say "Editing $SRC:   type Val = Text  ->  type Val = Int"
  bash scripts/05-variant.sh v2 >/dev/null 2>&1
  NEW=$(cat logs/pkgid-v2.txt); NEWDAR=artifacts/mirrors-v2.dar; TARGET=v2
fi
printf '\n'
hit "was  mirrors 1.0.0  $(echo "$V1" | cut -c1-12)..   (value : Text)"
hit "now  mirrors 1.0.0  $(echo "$NEW" | cut -c1-12)..   (value : Int)"
say "Same name. Same version. Different hash. A field type change can never be a valid upgrade."
say ""
say "So do the obvious thing -- upload it."
POC_DAR="$NEWDAR" console console/naive.canton 200 > logs/naive.out 2>&1
printf '\n'
grep -oE "KNOWN_PACKAGE_VERSION\([0-9,a-f]+\): Tried to vet two packages with the same name and version" logs/naive.out \
  | head -1 | sed 's/^/   \x1b[1;31mREJECTED  /;s/$/\x1b[0m/'
hit "          -> Canton will not run two packages with the same name and version."
say ""
say "Bumping to 1.0.1 does not help either: the upgrade checks then reject the type change."
say "So today there is exactly one way forward."
pause

# ---------------------------------------------------------------- act 2
act "ACT 2  so you restart the ledger.  Here is what that costs."
hit "before restart:   Alice $(sh_ "$A1")     contracts $(p_count "$F")"
say "Restarting... (your edit stays in the editor; only the ledger is thrown away)"
bash scripts/00-sandbox.sh >/dev/null 2>&1
F2=$(facts)
printf '\n'
hit "after restart:    parties $(printf '%s\n' "$F2" | grep -c 'ASSERT|party' || true)     contracts $(p_count "$F2")     PID $(sandbox_pid)  \033[2m(was $PID1)\033[0m"
bad "-> every party gone, every contract gone, new process."
say "Storage is in-memory, so a restart is a clean slate. Now re-seed to get working again:"
POC_MODEL_DAR=artifacts/mirrors-v1.dar POC_SEED_DAR=artifacts/mirrors-seed-v1.dar \
  bash scripts/10-seed.sh >/dev/null 2>&1
F3=$(facts); A3=$(p_alice "$F3"); PID3=$(sandbox_pid)
printf '\n'
hit "old Alice   $(sh_ "$A1")"
hit "new Alice   $(sh_ "$A3")"
bad "-> different party id. Any app holding the old one is now broken."
say "This is the price on every single save. That is the problem."
pause

# ---------------------------------------------------------------- act 3
act "ACT 3  the reload -- but in the wrong order." 
hit "starting point:   Alice $(sh_ "$A3")     contracts $(p_count "$F3")     PID $PID3     model Text"
say "Same edit you already made. The SAME package Canton just rejected in Act 1."
say "Difference: upload it UNVETTED, then swap the vetted set in one topology transaction."
printf '\n'
bash scripts/30-reload.sh "$TARGET" 2>&1 | grep -E "RELOAD force|RELOAD swapped|RELOAD orphaned|PASS|FAIL" | sed 's/^/   /'
F4=$(facts); A4=$(p_alice "$F4")
printf '\n'
[ "$A4" = "$A3" ] && hit "Alice        $(sh_ "$A4")   <- IDENTICAL" || bad "Alice CHANGED (unexpected)"
[ "$(sandbox_pid)" = "$PID3" ] && hit "PID          $PID3   <- IDENTICAL, never restarted" || bad "PID CHANGED (unexpected)"
hit "live model   $(p_live "$F4" | cut -c1-12)..   <- value : Int, still mirrors 1.0.0"
printf '\n'
good "-> incompatible model swapped into a running ledger. Same process, same parties."
say ""
say "But look at the contract count:"
printf '%s\n' "$F4" | awk -F'|' '$2=="acs" && $5=="ORPHAN"{s+=$6} END{ if (s>0) printf "   \033[1;33m%d contracts from the old model are STRANDED -- still active, unusable.\033[0m\n", s }'
say "The swap never touches contracts. It only changes which code may run."
say "So those are left behind -- and they cannot be exercised OR archived any more,"
say "because archiving also needs the code that understands them."
say ""
say "That is the wrong order. Watch the right one."
pause

# ---------------------------------------------------------------- act 4
act "ACT 4  the same reload, archiving FIRST."
say "Resetting the experiment to a clean ledger, then doing it in the right order."
bash scripts/00-sandbox.sh >/dev/null 2>&1
bash scripts/05-variant.sh v1 >/dev/null 2>&1
POC_MODEL_DAR=artifacts/mirrors-v1.dar POC_SEED_DAR=artifacts/mirrors-seed-v1.dar \
  bash scripts/10-seed.sh >/dev/null 2>&1
F5=$(facts); A5=$(p_alice "$F5"); PID5=$(sandbox_pid)
hit "starting point:   Alice $(sh_ "$A5")     contracts $(p_count "$F5")     PID $PID5"
printf '\n'
say "Step 1 -- archive the old contracts, as their signatories."
say "(in a dev sandbox we allocated every party, so we hold the authority)"
dpm script --dar artifacts/mirrors-seed-v1.dar --script-name Seed:cleanup \
  --ledger-host localhost --ledger-port 6865 -w 2>&1 | grep -oE "CLEANUP [^\\]*" | sed 's/^/   /'
F6=$(facts)
hit "contracts now $(p_count "$F6")   <- the window in which the swap is safe"
printf '\n'
say "Step 2 -- now the identical reload, plus dropping the old package."
printf '\n'
POC_REMOVE_OLD=true bash scripts/30-reload.sh "$TARGET" 2>&1 \
  | grep -E "RELOAD force|RELOAD swapped|RELOAD orphaned|RELOAD removeOld|PASS|FAIL" | sed 's/^/   /'
F7=$(facts); A7=$(p_alice "$F7")
printf '\n'
[ "$A7" = "$A5" ] && hit "Alice        $(sh_ "$A7")   <- IDENTICAL" || bad "Alice CHANGED (unexpected)"
[ "$(sandbox_pid)" = "$PID5" ] && hit "PID          $PID5   <- IDENTICAL, never restarted" || bad "PID CHANGED (unexpected)"
hit "live model   $(p_live "$F7" | cut -c1-12)..   <- value : Int, still mirrors 1.0.0"
printf '%s\n' "$F7" | awk -F'|' '$2=="dar"{n++} END{printf "   \033[1mmirrors packages on the ledger  %d   <- old one deleted\033[0m\n", n}'
printf '\n'
good "-> zero stranded contracts. One package. Nothing restarted."
say ""
say "The only thing left is history in the event log, and in-memory that grows until"
say "you restart. Canton can already delete it -- repair.purge works on Postgres, we"
say "tested it -- but it is refused on the in-memory sandbox developers actually use."
say ""
hit "THE ASK: make repair.purge available on an in-memory dev participant."
