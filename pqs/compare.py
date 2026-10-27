# compare.py <outdir> <tag> <pqs.tsv> <manifest-L1.tsv> [manifest-L2.tsv]
# Manifest rows: ledger, contract_id, offset, label, state ("active" | "archived@<off>").
# PQS rows: contract_id | active|archived | signatories. Prints KEY=VALUE lines; writes lists.
import sys, os
out, tag, pqs_f, *mans = sys.argv[1:]
man = {}
for f in mans:
    for line in open(f):
        led, cid, off, label, state = line.rstrip("\n").split("\t")
        man[cid] = (led, off, label, "archived" if state.startswith("archived") else "active")
pqs = {}
for line in open(pqs_f):
    parts = [p.strip() for p in line.rstrip("\n").split("|")]
    if len(parts) >= 2 and parts[0]:
        pqs[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
def write(name, rows):
    with open(os.path.join(out, f"{name}-{tag}.txt"), "w") as fh:
        fh.writelines(r + "\n" for r in rows)
    return len(rows)
for led in ("L1", "L2"):
    exp = {c: v for c, v in man.items() if v[0] == led}
    if not exp: continue
    missing = [f"{v[1]}\t{v[2]}\t{c}" for c, v in sorted(exp.items(), key=lambda kv: int(kv[1][1])) if c not in pqs]
    wrong = [f"{v[1]}\t{v[2]}\texpected={v[3]}\tpqs={pqs[c][0]}\t{c}" for c, v in exp.items() if c in pqs and pqs[c][0] != v[3]]
    print(f"{led}_expected={len(exp)}")
    print(f"{led}_present={sum(1 for c in exp if c in pqs)}")
    print(f"{led}_missing={write('missing-' + led, missing)}")
    print(f"{led}_wrongstate={write('wrongstate-' + led, wrong)}")
    print(f"{led}_missing_offsets={','.join(m.split(chr(9))[0] for m in missing) or '-'}")
print(f"unexpected={write('unexpected', [c for c in pqs if c not in man])}")
print(f"pqs_rows={len(pqs)}")
