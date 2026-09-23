# Canton development reload — evidence base

**This repository is evidence, not a product.** It holds the test harness and committed run logs
behind [`proposals/2026-09-LimeChain-FRED-v4.md`](proposals/2026-09-LimeChain-FRED-v4.md),
the current draft (the longer first edition is retained beside it),
a Canton Development Fund proposal. Every claim that proposal makes maps to a log file here that you
can open and read. The tool the proposal asks to fund does not exist yet.

**Start at [`evidence/INDEX.md`](evidence/INDEX.md)** — it maps each claim to the run that backs it,
states the rules for reading them, and lists explicitly what these runs do *not* establish.

## What was demonstrated

A Daml model was changed **incompatibly** — `type Val = Text` → `type Val = Int` — on a **running**
Canton 3.5.12 participant. Same package name, same version, no restart, no force flag.

The participant process and every **party ID** survive. Contracts do **not**: they are archived and
recreated, so contract IDs change. That distinction matters and the proposal is careful about it.

The sequence: archive the old contracts → `dars.upload(dar, vetAllPackages = false)` → swap the
vetted set in **one** `propose_delta` against the synchronizer store → reseed.

Measured over 10 alternating trials per path: the reload reaches a verified seeded state in a median
**18.5 s**, against **30.6 s** to restart and reseed — a 39.5% reduction, and a conservative one,
since it excludes repairing everything that still holds the old party IDs after a restart.

## Requirements

- **`dpm`** — tested with 1.0.21 / dpm-sdk 3.5.5 / Canton 3.5.12.
- **An OpenJDK 17+, not an Oracle JDK.** Canton's fat jar bundles BouncyCastle unsigned; Oracle JDKs
  refuse to authenticate it and *every transaction submit* fails with an opaque `INTERNAL`. Verified:
  Oracle 17.0.7 fails, Oracle 18.0.2 fails, OpenJDK 21.0.12.1 works. `scripts/lib.sh` points
  `JAVA_HOME` at an OpenJDK if it finds one and warns loudly if it does not; your global environment
  is untouched. `brew install openjdk@21`.
- **`python3`** — used for timing arithmetic in `scripts/80-timing.sh`.
- **macOS.** Every result here was produced on macOS with OpenJDK 21. The scripts use `shasum`,
  `nc`, BSD `ps` and Homebrew paths; Linux is untested.
- **Fetch the tags.** A clone without them, or a tarball download, leaves no `harness-*` tag
  reachable, and every run will correctly refuse to produce a citable result. `git fetch --tags`.

## Verifying a claim

Each command below starts from a clean sandbox, asserts its own expectations, and **exits non-zero
if any of them fail**. A run that cannot prove its own provenance refuses to produce a result rather
than printing a green line — so if a command stops with `VOID`, that is the harness working.

```bash
git fetch --tags                     # required, see above

bash scripts/70-matrix.sh C1         # unforced add-second is REJECTED (KNOWN_PACKAGE_VERSION)
bash scripts/70-matrix.sh C2         # the same call forced is ACCEPTED
                                     #   C1+C2 are the control pair: they prove the harness can
                                     #   tell the two force settings apart at all
bash scripts/70-matrix.sh E1         # the swap, unforced, contracts archived first  <- the headline
bash scripts/70-matrix.sh E2         # the swap, unforced, contracts still live (strands them)
bash scripts/70-matrix.sh E3         # the swap WITH the flag — identical outcome to E1
bash scripts/70-matrix.sh E4         # unvetting with live contracts, unforced
bash scripts/70-matrix.sh E5         # the same unvet with the flag — inert, identical to E4
bash scripts/70-matrix.sh E6         # three independent repeats of E1 (determinism)

bash scripts/71-closure.sh M1        # dependent not rebuilt -> PACKAGE_SELECTION_FAILED
bash scripts/71-closure.sh M2        # the closure loop end to end, one topology transaction

bash scripts/60-story.sh --no-pause  # the four acts, reload defaulting to no force flag
bash scripts/80-timing.sh 11         # reload vs restart, 10 measured trials per path
```

**Expect roughly:** a matrix row ~1 minute, a closure row ~2 minutes, the story ~4 minutes, the
timing run ~35 minutes (22 trials, each from a full sandbox reset).

**What success looks like.** Every run prints its expectations up front, then a line per assertion,
then a verdict:

```
#### ROW E1  op=swap force=none state=archived
#### EXPECT result=succeed v1Vetted=false v2Vetted=true serialDelta=1 acs=0 onV1=0
...
assert_committed PASS  no committed change outside evidence/ since harness-v5
assert_clean     PASS  working tree clean outside evidence/
OP   forceFlagsActual=ForceFlags(Set()) forceIsNone=true adds=[dba33b18bff3] removes=[c17b5cb16a9d]
RESULT op=swap force=none forceIsNone=true => SUCCEEDED
ASSERT serialDelta    PASS got=1 want=1
VERDICT PASS
#### ROW E1 PASS
```

Two lines are worth understanding:

- **`OP forceFlagsActual=…`** is the force flag *as reconstructed from what was passed to Canton*,
  not as requested by a label. An earlier version of this harness chose the flag with a string test
  that the operation names happened to satisfy, so runs labelled "unforced" had the flag set. That
  defect, and the control pair built to catch it, are described in `evidence/INDEX.md`.
- **`assert_clean` / `assert_committed`** anchor the run to a `harness-*` tag. If the working tree
  has any change outside `evidence/`, the run voids itself rather than producing a citable result.

## The demo

```bash
bash scripts/60-story.sh --no-pause    # citable; writes a log to evidence/
bash scripts/60-story.sh --live        # you hand-edit the model; NOT citable
```

Four acts: a breaking change is rejected; restarting loses every party and contract; reloading in
the wrong order strands contracts; reloading in the right order strands nothing.

`--live` pauses so you can edit `mirrors/daml/Mirrors.daml` yourself. It writes **no** evidence log —
editing a tracked source mid-run would make any provenance header false — and it restores your
original file on exit, including any edit you already had there.

## Layout

| Path | What it is |
|---|---|
| `evidence/` | Committed run logs. `INDEX.md` maps each to the claim it backs. **Start here.** |
| `scripts/` | The harness. Only four are meant to be run directly — see below. |
| `console/` | Canton console bootstrap scripts, driven by `scripts/`. |
| `console/historical/` | Scripts whose fixtures no longer exist. Not reproducible; see its README. |
| `mirrors/`, `seed/` | The single-package model under test, and its Daml Script seed package. |
| `multi/` | The three-package project (`items` → `holders` → `seedab`) used for closure tests. |
| `variants/` | The v1/v2 sources. `Mirrors.v1` is `Text`, `v2` is `Int` — an invalid upgrade. |
| `canton/` | Sandbox configs. |
| `proposals/` | The Dev Fund proposal this repository is evidence for. |
| `tools/` | Document utilities, not harness. `build-docx.sh` renders the proposal to `.docx`. |
| `rfc/` | The superseded internal RFC that led to the proposal. |
| `RESULTS.md` | Internal findings write-up, predating the evidence rebuild. See its header. |

### Scripts: four drivers, the rest are steps

Only these four are meant to be typed:

| Driver | Produces |
|---|---|
| `70-matrix.sh <ROW>` | One force-matrix row (`C1 C2 E1..E6`) |
| `71-closure.sh <ROW>` | One multi-package row (`M1 M2`) |
| `60-story.sh` | The four-act demo |
| `80-timing.sh [N]` | The reload-vs-restart measurement |

The rest are steps the drivers call in order — `00-sandbox` (fresh participant), `05-variant` /
`06-variant-multi` (build a model variant), `10-seed` (upload and seed), `30-reload` (the reload
itself) — plus `lib.sh` (JDK pin, console wrapper) and `env-stamp.sh` (the provenance header).

Builds never touch the tracked sources: `05-variant.sh` materialises a throwaway project under a
gitignored `.gen-*` directory and builds there. That is what lets `assert_clean` demand a spotless
tree with no exclusions.

## What this does not establish

Summarised here, in full in [`evidence/INDEX.md`](evidence/INDEX.md):

- **Pruning was not tested.** There is no pruning script and no log. The honest position is "we did
  not test pruning", not "pruning does not work".
- **`repair.purge`** was exercised by hand against a Postgres sandbox with no committed log, and the
  script for it now sits in `console/historical/` because nothing here can start that sandbox.
- **Approach 1** (the compatible version bump) is not reproducible — its DARs are gone. See
  `console/historical/`.
- **PQS** was not tested; a polling JSON-API consumer was substituted.
- **Multi-participant** behaviour and **in-flight submissions during the swap** are untested.
- **One machine.** macOS, OpenJDK 21, single-participant in-memory sandbox.

## Caveats on the technique itself

- **Development only.** It works because you allocated every party yourself and therefore hold the
  signatory authority to archive their contracts. That is not true anywhere else.
- **Single-participant sandbox only.** On a shared synchronizer, contracts are shared and unilateral
  ACS manipulation risks ACS-commitment mismatches.
- **`storage = memory`**, so a restart loses everything — which is what makes "we did not restart" a
  meaningful claim, and also why `repair.*` is unavailable.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
