# Canton dev model reload — POC

Change a Daml model on a **running** Canton participant: same package name, same version, no
version bump, no restart, parties intact.

The question this answers:

> Can it be done with the APIs that ship in Canton 3.5.12, and if not, exactly which call stops us?

**Answer: yes, two ways, neither needing a Canton change.**

| Your change | Approach | Dependent packages |
|---|---|---|
| **compatible** (add an optional field, add a choice) | bump the version, `1.0.0` → `1.0.1` | resolve automatically, no rebuild |
| **incompatible** (change a type, drop a field) | **archive** → upload unvetted → swap → reseed | must be rebuilt too |

The only unsolved problem is reclaiming storage afterwards. Full evidence, with verbatim error
strings, in **[RESULTS.md](RESULTS.md)**; the proposal in **[rfc/RFC-revised.md](rfc/RFC-revised.md)**.

## Requirements

- `dpm` (tested 1.0.21 / dpm-sdk 3.5.5 / Canton 3.5.12)
- **An OpenJDK 17+, not an Oracle JDK.** Canton's fat jar bundles BouncyCastle unsigned; Oracle
  JDKs refuse to authenticate it and *every transaction submit* fails with an opaque
  `INTERNAL`. `scripts/lib.sh` points `JAVA_HOME` at `/opt/homebrew/opt/openjdk@21` if present
  and leaves your global environment alone. `brew install openjdk@21`.

## Run it

```bash
bash scripts/60-story.sh --live
```

Four acts, pausing between each so you can talk. In act 1 it waits while **you** hand-edit one
line of the model — `type Val = Text` → `type Val = Int` — and tells you if the file was not
saved.

| Act | What it shows |
|---|---|
| **Setup** | a working dev ledger: parties allocated, data seeded |
| **1** | you change one line, rebuild, upload — **Canton rejects it**, with the real `KNOWN_PACKAGE_VERSION` error |
| **2** | so you restart, and **lose every party and contract**; re-seeding hands you different party IDs |
| **3** | the reload in the **wrong order** — works, but strands contracts that can no longer be archived |
| **4** | the reload **archiving first** — nothing stranded, old package removed, same PID and party IDs |

Add `--no-pause` to rehearse straight through (skips the hand edit). Drop `--live` to have the
script swap the variant itself.

One reload takes ~12s; nearly all of that is JVM startup across three processes, not Canton.

## How the reload works

```
1. archive the old contracts               ordinary Daml Archive, as the signatories.
                                           The only valid window — after the swap the old
                                           package is unvetted and nothing from it can be
                                           exercised, archiving included.
2. dars.upload(dar, vetAllPackages = false)  incompatible builds upload fine when unvetted
3. topology.vetted_packages.propose_delta(   ONE transaction: old out, new in
     adds    = [ VettedPackage(newId) ],
     removes = [ oldId ],
     store   = TopologyStoreId.Synchronizer(psid))   <- NOT the default Authorized store
4. reseed                                  parties are reused, not reallocated
5. dars.remove(oldId)                       optional; only possible because step 1 archived
```

Two things that are easy to get wrong:

- **Target the synchronizer store.** `propose_delta` defaults to the *Authorized* store, which
  on a fresh participant has no `VettedPackages` mapping — so a defaulted call emits serial 1,
  silently changes nothing, and still returns success.
- **`dars.vetting.enable` cannot express this.** It has no force parameter, so it fails with
  `KNOWN_PACKAGE_VERSION`. Only the topology API can do the swap.

No force flag is needed: `KNOWN_PACKAGE_VERSION` is evaluated against the *resulting* vetted
set, and an atomic swap never produces two packages sharing a name and version.

## Order matters: archive first

The swap does **not** touch contracts. Archive after it and the old contracts are stranded —
active but unusable, and no longer archivable either, because archiving also needs the code
that understands them. `scripts/30-reload.sh` reports the count as `orphanedContracts`.

Archiving beforehand gives `orphanedContracts=0` and is what makes `dars.remove` succeed,
leaving exactly one `mirrors 1.0.0` carrying the new types. It works because in a development
sandbox you allocated every party yourself, so you hold the signatory authority — which is also
why the technique is inherently development-only.

What remains is **history** in the event log. With `storage = memory` it grows until you
restart. `repair.purge` deletes contracts outright and is verified working on Postgres, but is
refused in-memory; pruning never succeeded on either backend. That is the one open ask.

## Layout

```
mirrors/         the model under test. daml.yaml name+version are NEVER edited.
variants/        Mirrors.v1.daml (Text) and Mirrors.v2.daml (Int) — an invalid upgrade
seed/            Daml Script package: seed + cleanup. Separate so the uploaded DAR contains
                 ONLY the model; never uploaded itself (dpm script --upload-dar defaults false)
multi/           two-package project (items + holders) used to test dependent packages
canton/          sandbox.conf, and sandbox-pg.conf for the Postgres repair.purge test
console/         canton-console bootstrap scripts
scripts/         the runnable harness; lib.sh holds the JDK pin and the console wrapper
artifacts/       built DARs
rfc/             RFC-revised.md — the proposal
multi-package.yaml   so Daml Studio can resolve every package in the repo
```

## Reproducing the evidence

Each of these was run to establish a specific claim in `RESULTS.md`:

```bash
. scripts/lib.sh
POC_V1=$(cat logs/pkgid-v1.txt) POC_V2=$(cat logs/pkgid-v2.txt) console console/ladder-a.canton
console console/one-op.canton        # the swap needs no force flag
console console/unvet-test.canton    # unvetting with live contracts succeeds, unforced
console console/forcebump.canton     # forcing an incompatible bump is a trap
console console/upgrade-test.canton  # compatible bump accepted live, incompatible rejected
console console/swap-both.canton     # two packages swapped in one transaction
console console/pv2.canton           # the sandbox runs stable protocol version 35
console console/purge-pg.canton      # repair.purge — needs canton/sandbox-pg.conf
```

## Caveats

- Single-participant sandbox only. On a multi-participant synchronizer contracts are shared, so
  unilateral ACS manipulation risks ACS-commitment mismatches.
- `storage = memory`, so a restart loses everything — which is what makes "we did not restart" a
  meaningful claim, and also why `repair.*` is unavailable.
- A Postgres-backed sandbox is not a workaround: `dpm sandbox` re-runs topology initialisation
  on startup and fails against already-initialised databases.
