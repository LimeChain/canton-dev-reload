#!/usr/bin/env bash
# ln-ln5.sh: fresh LocalNet + v1 fixture, then ln-ln5.canton while streaming only WARN/ERROR/codes from the
# canton and splice containers; then per WINDOW counts. Out: logs/ln-ln5/.
set -uo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/.." && pwd)"; Q="$R/.qs/quickstart"; M="$Q/docker/modules/localnet"; O="$R/logs/ln-ln5"; mkdir -p "$O"
(cd "$Q" && make clean-localnet >/dev/null 2>&1; make start-localnet LOCALNET_ONLY_RESOURCE_CONSTRAINTS="-f $M/resource-constraints.yaml -f $L/ln-logcap.yaml" > "$O/up.log" 2>&1)
rm -f "$L/state/fred.checkpoint"; cp "$R/variants/Shared.v1.daml" "$R/.gen-shared/v2/daml/Shared.daml"
"$L/ln-run.sh" ln-fixture.canton > "$O/fixture.out" 2>&1; V1=$(sed -n 's/^PKG V1=//p' "$O/fixture.out"); [ -n "$V1" ] || { echo "fixture failed"; exit 1; }
F='"level":"(WARN|ERROR)"|ACS_COMMITMENT_MISMATCH|ACS_MISMATCH_NO_SHARED|SEQUENCER_OVERLOADED'
for c in canton splice; do (docker logs -f --since 1s "$c" 2>&1 | grep --line-buffered -E "$F" > "$O/$c.filtered.log") & done
"$L/ln-run.sh" ln-ln5.canton -e LN_V1="$V1" -e LN_RECON_S="${LN_RECON_S:-10}" -e LN_HOLD_S="${LN_HOLD_S:-190}" > "$O/ln5.out" 2>&1
sleep 5; pkill -f "docker logs -f --since 1s" 2>/dev/null
grep -E '^(NOTE|ASSERT|VERDICT|WINDOW|EXPECT)' "$O/ln5.out"
python3 - "$O" <<'PY'
import sys,json,re,collections,datetime as dt
o=sys.argv[1]; W=[l.split()[1:] for l in open(f"{o}/ln5.out") if l.startswith("WINDOW")]
def ts(j): return int(dt.datetime.fromisoformat(j["@timestamp"].replace("Z","+00:00")).timestamp()*1000)
for c in ("canton","splice"):
    E=[]
    for l in open(f"{o}/{c}.filtered.log",errors="ignore"):
        try: j=json.loads(l)
        except: continue
        E.append((ts(j),j))
    for n,s,e in W:
        s,e=int(s),int(e)+15000  # +15s tail for late commitment checks
        cnt=collections.Counter()
        for t,j in E:
            if s<=t<=e:
                m=j.get("message",""); code=(re.findall(r"ACS_COMMITMENT_MISMATCH|ACS_MISMATCH_NO_SHARED_CONTRACTS|SEQUENCER_OVERLOADED|[A-Z][A-Z_]{8,}[A-Z]",m) or [re.sub(r"\d+|[0-9a-f]{12,}","#",m)[:70]])[0]
                cnt[(j["level"],j.get("logger_name","").split(":")[0].split(".")[-1][:24],code)]+=1
        print(f"LOGS {c} {n}: {sum(cnt.values())} entries", "; ".join(f"{v}x {k[0]} {k[1]} {k[2]}" for k,v in cnt.most_common(8)))
PY
