# Evidence index

Every run here was produced from a clean sandbox by `scripts/70-matrix.sh`, `scripts/71-closure.sh`,
`scripts/60-story.sh` or `scripts/80-timing.sh`, and carries a provenance header naming the harness
revision that produced it. A run that cannot assert its own provenance — dirty tree, drifted
harness, or no reachable tag — voids itself and exits non-zero rather than producing a citable
result.

**Reading rule.** Each log's `RESULT` line states the resolved force argument as reconstructed
from the value actually passed to Canton, not as requested by a label. Any quoted console output
in the proposal must be a verbatim contiguous excerpt from exactly one file listed here.

**Comparison rule.** Rows are only comparable within a single `HARNESS_REV`. The revisions differ
as follows:

| Tag | What changed |
|---|---|
| `harness-v1` | Force matrix harness. `reload.canton` still defaults to `AllowVetIncompatibleUpgrades`, i.e. the shipped behaviour at the time. |
| `harness-v2` | Adds the closure rows; flips `reload.canton`'s default to `ForceFlags.none` (gated on E1/E2); corrects the oracle interpretation. |
| `harness-v3` | `60-story.sh` no longer filters out the `RELOAD force=` line. |
| `harness-v4` | Adds `scripts/80-timing.sh` and the source-write instant captured by `05-variant.sh`. |
| `harness-v5` | Publication revision: every driver voids on any failed provenance check, `60-story.sh` gained a provenance header and machine-checked assertions for all the properties it is cited for, and the orphaned ladder/upload2/swap-both scripts were removed. |

## Force-flag matrix (harness-v1)

Common setup: `mirrors` v1 (`Text`) vetted with 2 active contracts; v2 (`Int`) uploaded unvetted.
`Δ` is the synchronizer-store `VettedPackages` serial delta. `onV1` counts active contracts whose
package is v1.

| Row | Operation | Force argument | Contracts | Result | Δ | Licenses |
|---|---|---|---|---|---|---|
| C1 | `add-second` | `ForceFlags.none` | 2 live | **FAILED** `KNOWN_PACKAGE_VERSION` | 0 | positive control |
| C2 | `add-second` | `AllowVetIncompatibleUpgrades` | 2 live | SUCCEEDED, both vetted | 1 | positive control |
| E1 | `swap` | `ForceFlags.none` | archived | SUCCEEDED, `onV1=0` | 1 | **the headline: the swap needs no force flag** |
| E2 | `swap` | `ForceFlags.none` | 2 live | SUCCEEDED, `onV1=2` | 1 | story Act 3; swap works unforced with live contracts |
| E3 | `swap` | `AllowVetIncompatibleUpgrades` | archived | identical to E1 | 1 | the flag changes nothing on this path |
| E4 | `unvet` | `ForceFlags.none` | 2 live | SUCCEEDED | 1 | **RFC §5**, from a genuinely unforced run |
| E5 | `unvet` | `AllowVetIncompatibleUpgrades` | 2 live | identical to E4 | 1 | the flag is inert when `adds` is empty |
| E6 r1–r3 | `swap` | `ForceFlags.none` | archived | three identical repeats of E1 | 1 | determinism |

**C1 and C2 are the gate.** They establish that the harness can distinguish the two force settings
at all. Without them, a run that never passed `none` and a run whose `none` was silently ignored
produce identical output, and "no force flag is needed" is unfalsifiable by our own harness.

## Dependency closure (harness-v2)

| Row | Scenario | Result |
|---|---|---|
| M1 | Rebuild `items` only; leave `holders` and the client script at v1. Swap `items` alone, unforced. | `PEEK holders=1`, then `PACKAGE_SELECTION_FAILED(9,…): No synchronizers satisfy the topology requirements`. The dependent-not-rebuilt control. |
| M2 | Archive first, rebuild all three, upload both unvetted, **one** `propose_delta` `adds=[newA,newB] removes=[oldA,oldB]` unforced, reseed, peek. | SUCCEEDED, Δ=1, both old unvetted, both new vetted, `PEEK holders=1`, `PEEK label=1`. **First end-to-end run of the closure loop as a single operation.** |

Package IDs are the historical ones: `items` v1 `f598c7e1de1b` → v2 `04d8ea17faef`,
`holders` v1 `92c6c3f57ebf` → v2 `3069c0dc4233`.

## Timing (harness-v4)

`scripts/80-timing.sh`, 11 trials per path, alternating, first of each discarded as warm-up, every
trial from a fresh sandbox + rebuilt v1 + fresh seed performed outside the timed interval.

| Path | n | median | min | max |
|---|---|---|---|---|
| reload | 10 | **19.86 s** | 19.19 s | 21.20 s |
| restart and reseed | 10 | **33.36 s** | 32.38 s | 34.91 s |

**Reduction: 40.5%** (median to median).

Protocol, in full, in the log header. The parts that matter for reading the number:

- **Start** is the source write, captured by `05-variant.sh` into `logs/t0.source-write` immediately
  before it copies the variant in — an observed event, not a reconstructed timestamp.
- **End** is an *equivalent logical seeded state* (`console/verify-seeded.canton`): parties exist and
  seed data is present. The restart path reaches it with **newly allocated party IDs**, which is
  permitted — the condition is logical equivalence, not identity.
- **Excluded**: repairing scripts, config and fixtures that still hold the old party IDs after a
  restart. Real, but unbounded and project-specific, so the measured advantage is a **conservative
  floor** rather than the full cost difference.
- **Prototype, not product.** `dpm dev-reload` does not exist; these trials time the existing
  shell/console orchestration. Both paths pay repeated JVM startup — the reload path launches five
  processes (build, archive script, console, reseed script, verify console). The per-component split
  was not separately instrumented in this run.

Party-ID preservation is **not** part of this measurement — see the `STORY` row, where it is
evidenced separately as a reload-only property.

## Story (harness-v3)

`60-story.sh --no-pause`, with `reload.canton` defaulting to `ForceFlags.none`:

- Act 3 (swap before archiving): `RELOAD force=none`, Δ=1, `orphanedContracts=2`
- Act 4 (archive first): `RELOAD force=none`, Δ=1, `orphanedContracts=0`, `removeOld=DONE`
- Both acts: participant PID unchanged, Alice's party ID identical, ledger API still open

## What these runs do NOT establish

- **Pruning.** No run here touches it. There is still no pruning script in the repo and
  `UNSAFE_TO_PRUNE` appears nowhere in the participant logs. The honest position remains
  "we did not test pruning", not "pruning did not work".
- **`repair.purge`.** Not re-run here and it has **no committed log**; the claim rests on a
  by-hand run against a Postgres sandbox that nothing in this repo can start. The script now sits
  in `console/historical/`.
- **Approach 1** (compatible version bump). `console/historical/upgrade-test.canton`, `forcebump.canton` and
  `upg2.canton` still load DARs from `/private/tmp` that do not exist, so that section of
  RESULTS.md is not reproducible and must be labelled historical until those fixtures are restored.
- **PQS**, multi-participant behaviour, and in-flight submissions during the swap: untested.
- **Contract identities.** The loop archives and recreates contracts; only the participant process
  and the party IDs survive.
