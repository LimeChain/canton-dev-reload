# Evidence index

Every run here was produced from a clean sandbox by `scripts/70-matrix.sh`, `scripts/71-closure.sh`,
`scripts/72-multisync.sh`, `scripts/73-pqs.sh`, `scripts/60-story.sh` or `scripts/80-timing.sh`, and carries a provenance header naming the harness
revision that produced it. A run that cannot assert its own provenance — dirty tree, drifted
harness, or no reachable tag — voids itself and exits non-zero rather than producing a citable
result.

**Reading rule.** Each log's `RESULT` line states the resolved force argument as reconstructed
from the value actually passed to Canton, not as requested by a label. Any quoted console output
in the proposal must be a verbatim contiguous excerpt from exactly one file listed here.

**Comparison rule.** Rows are only comparable within a single `HARNESS_REV`. **Every log in this
directory except `MS1` was produced at `harness-v5`**, in a single pass from a neutral checkout, so
those rows are directly comparable to each other. `harness-v6` to `harness-v23` are documentation-only
revisions that leave the harness byte-identical, so these logs remain current at the published tip —
each row below says what changed, and `git diff --stat harness-v5 <tag> -- scripts console` is empty
for every one of them. `harness-v24` adds the `MS1` row as two new files and changes no existing one,
so `git diff --stat harness-v5 harness-v24 -- scripts console` lists only those two additions and the
v5 logs remain current. `MS1` was produced at `harness-v24` and stands on its own. The PQS rows under `pqs/` were produced at `harness-v26` and stand on their own in the same way. The tag history is
kept below because the narrative of how the evidence was corrected depends on it.

| Tag | What changed |
|---|---|
| `harness-v1` | Force matrix harness. `reload.canton` still defaults to `AllowVetIncompatibleUpgrades`, i.e. the shipped behaviour at the time. |
| `harness-v2` | Adds the closure rows; flips `reload.canton`'s default to `ForceFlags.none` (gated on E1/E2); corrects the oracle interpretation. |
| `harness-v3` | `60-story.sh` no longer filters out the `RELOAD force=` line. |
| `harness-v4` | Adds `scripts/80-timing.sh` and the source-write instant captured by `05-variant.sh`. |
| `harness-v5` | Publication revision: every driver voids on any failed provenance check, `60-story.sh` gained a provenance header and machine-checked assertions for all the properties it is cited for, and the orphaned ladder/upload2/swap-both scripts were removed. |
| `harness-v6` | **Documentation only.** Corrected the timing figures to match the committed `TIMING` run and moved the docx utility out of `scripts/`. The harness is byte-identical to `harness-v5` — check with `git diff --stat harness-v5 harness-v6 -- scripts console`. The logs here were produced at v5 and remain current. |
| `harness-v7` | **Documentation and document tooling only.** Milestone 1's iteration-time target was restored to ≥40% and the docx utility now also emits a Markdown copy. The harness is byte-identical to `harness-v5` — check with `git diff --stat harness-v6 harness-v7 -- scripts console`. The logs here were produced at v5 and remain current. |
| `harness-v8` | **Documentation only.** The proposal now links the public repository, pinned to the `harness-v7` tag rather than to `main`. Harness byte-identical to `harness-v5`. |
| `harness-v9` | **Documentation only.** §2 now answers why `dpm test` and the Daml Studio script runner do not cover this, and the repository links are re-pinned to this tag. Harness byte-identical to `harness-v5`. |
| `harness-v10` | **Documentation only.** Potential Follow-Ons now names long-running integration environments and unattended CI use, and the repository links are re-pinned to this tag. Harness byte-identical to `harness-v5`. |
| `harness-v11` | **Documentation only.** Adds a second edition of the proposal, cut by 61% to Champion feedback, and answers the append-only-log question in the design note. Harness byte-identical to `harness-v5`. |
| `harness-v12` | **Documentation only.** The second edition names the component FRED and moves to `proposals/2026-09-LimeChain-FRED.md`. Harness byte-identical to `harness-v5`. |
| `harness-v13` | **Documentation only.** Adds a third edition recasting Fred as a development loop supervisor, per Champion feedback. Harness byte-identical to `harness-v5`. |
| `harness-v14` | **Documentation only.** Adds a fourth edition: the one-shot command becomes Milestone 1 and the live sandbox is built on it, with PQS as a managed component. Harness byte-identical to `harness-v5`. |
| `harness-v15` | **Documentation only.** Renames the product's setup hook, makes the auto policy disarm after a failed commit, simplifies reset, and states the configuration principle. Harness byte-identical to `harness-v5`. |
| `harness-v16` | **Documentation only.** Merges the command and closure milestones, separates PQS from adoption, and cuts delivery effort to 11 engineer-weeks. Harness byte-identical to `harness-v5`. |
| `harness-v17` | **Documentation only.** Fills the team track record and rewrites Co-Marketing with the release assets. Harness byte-identical to `harness-v5`. |
| `harness-v18` | **Documentation only.** Moves Motivation and Rationale ahead of Specification, matching the PQS reference proposal. Harness byte-identical to `harness-v5`. |
| `harness-v19` | **Documentation only.** Points the reader at the appendix from Motivation and Implementation Mechanics, and restores the withdrawn protocol ask to Rationale. Harness byte-identical to `harness-v5`. |
| `harness-v20` | **Documentation only.** Replaces three prose semicolons with full stops. Harness byte-identical to `harness-v5`. |
| `harness-v21` | **Documentation only.** Deliverables become bullet lists, removing 23 semicolons. Harness byte-identical to `harness-v5`. |
| `harness-v22` | **Documentation only.** Fixes the milestone delivery and effort lines running together. Harness byte-identical to `harness-v5`. |
| `harness-v23` | **Documentation only.** Corrects the design note: removing the old DAR does **not** make its history unreadable, so no DAR retention is required when PQS is attached. The earlier claim was reasoning, not a result. Carries no committed log, like the `repair.purge` claim below. Harness byte-identical to `harness-v5`. |
| `harness-v24` | **Harness addition.** Adds the multi-synchronizer row: `scripts/72-multisync.sh` and `console/multisync.canton`. No existing script or console file changes, so the v5 logs remain current. The `MS1` log was produced at this tag. |
| `harness-v25` | **Documentation only.** Commits the `MS1` log and indexes it below. Harness byte-identical to `harness-v24`. |
| `harness-v26` | **Harness addition.** Adds the PQS rows: `pqs/` (suite, console scripts, fixtures and their sources) and `scripts/73-pqs.sh`. No existing script or console file changes, so the v5 and `MS1` logs remain current. The PQS logs were produced at this tag. |
| `harness-v27` | **Documentation only.** Commits the PQS logs (`evidence/pqs/`) and indexes them below, and corrects the design note: the `harness-v23` reversal was wrong for PQS. The participant does serve the old events after the DAR is removed, but PQS cannot ingest them (`PQS-D`), so Fred keeps old DARs while PQS is attached. Harness byte-identical to `harness-v26`. |

## Force-flag matrix

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

## Dependency closure

| Row | Scenario | Result |
|---|---|---|
| M1 | Rebuild `items` only; leave `holders` and the client script at v1. Swap `items` alone, unforced. | `PEEK holders=1`, then `PACKAGE_SELECTION_FAILED(9,…): No synchronizers satisfy the topology requirements`. The dependent-not-rebuilt control. |
| M2 | Archive first, rebuild all three, upload both unvetted, **one** `propose_delta` `adds=[newA,newB] removes=[oldA,oldB]` unforced, reseed, peek. | SUCCEEDED, Δ=1, both old unvetted, both new vetted, `PEEK holders=1`, `PEEK label=1`. **First end-to-end run of the closure loop as a single operation.** |

Package IDs, which the builds reproduce exactly: `items` v1 `f598c7e1de1b` → v2 `04d8ea17faef`,
`holders` v1 `92c6c3f57ebf` → v2 `3069c0dc4233`.

## Multi-synchronizer

`scripts/72-multisync.sh` against `dpm sandbox --multi-sync`: the `sandbox` participant connected to
`synchronizer-1` (A) and `synchronizer-2` (B), `mirrors` v1 (`Text`) → v2 (`Int`). Log:
`20261021T132713Z__MS1__multisync.log`, produced at `harness-v24`, 37 assertions and 5 error codes, all PASS.

| Claim | Assertions | Result |
|---|---|---|
| An upload that also vets fails when two synchronizers are connected | `q1UploadVetFails`, `q1V1NotVetted`, `code-q1` | FAILED `PACKAGE_SERVICE_CANNOT_AUTODETECT_SYNCHRONIZER`; v1 vetted nowhere. Uploading unvetted and vetting per synchronizer works (`v1VettedOnBoth`). |
| Vetting is per synchronizer, and each swap needs no force flag | `q2SwapAUnforced`, `q2SerialA`, `q2SerialBUnchanged`, `q2VettedA`, `q2VettedBUntouched`, `q4SwapBUnforced`, `q4SerialB`, `q4OnlyV2OnBoth` | The swap on A moves A's serial by 1 and leaves B's at 0; the swap on B then completes it. `ForceFlags.none` throughout. |
| Between swaps, the old package stays usable on the unswapped synchronizer | `q3NewRoutesToA`, `q3NewRejectedOnB`, `code-q3newB`, `q3OldStillUsable`, `q3CheckCatchesStray` | v2 routes to A and is refused on B (`INVALID_PRESCRIBED_SYNCHRONIZER_ID`); **a v1 create still succeeds, routed to B**. The no-old-contracts check before B's swap catches it. |
| After both swaps the old package is unusable | `q4NewUsableOnB`, `q4OldRejected`, `code-q4old` | v2 creates on B; v1 is refused everywhere (`NO_SYNCHRONIZER_FOR_SUBMISSION`). |
| A contract left mid-reassignment is stranded | `q5InFlightListed`, `q5InFlightInAcs`, `q5InFlightArchiveFails`, `code-q5archive`, `q5LateAssignSucceeds`, `q5StrandedNoArchive`, `code-q5stranded`, `q5StrandedOnUnvetted` | It stays in the active set but cannot be archived (`UNKNOWN_CONTRACT_SYNCHRONIZERS`). Its assignment still succeeds after the swap, landing it on a synchronizer where its package is unvetted, where archival is refused. |
| Completing the reassignment before archival prevents that | `q6AssignBeforeArchive`, `q6RemedyNotStranded` | The contract whose reassignment was completed first is archived normally and is not left on v1. |

**Inputs.** This host cannot run `damlc` (x86_64 only, no Rosetta), so the row reused the
`mirrors-v1.dar` and `mirrors-v2.dar` built by the harness on 2026-09-17 (`POC_PREBUILT_DIR`). The
log asserts that each DAR's recorded source blob equals the committed `variants/Mirrors.v*.daml`
(`prebuilt-v1-source`, `prebuilt-v2-source`) and that Canton derives the recorded package id on upload
(`v1PackageId` `c17b5cb16a9d`, `v2PackageId` `dba33b18bff3`). On a host that can build, the driver
builds them from source with `05-variant.sh` instead.

**Scope.** One participant. Several participants across several synchronizers is not covered here.

## Timing

`scripts/80-timing.sh`, 11 trials per path, alternating, first of each discarded as warm-up, every
trial from a fresh sandbox + rebuilt v1 + fresh seed performed outside the timed interval.

| Path | n | median | min | max |
|---|---|---|---|---|
| reload | 10 | **18.50 s** | 17.91 s | 19.52 s |
| restart and reseed | 10 | **30.58 s** | 29.37 s | 33.07 s |

**Reduction: 39.5%** (median to median).

The figure carries a few points of run-to-run variance: an earlier run of the same protocol on the
same machine measured 40.5%. Only the run committed here is citable, so 39.5% is the number the
proposal uses.

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

## Story

`60-story.sh --no-pause`, with `reload.canton` defaulting to `ForceFlags.none`:

- Act 3 (swap before archiving): `RELOAD force=none`, Δ=1, `orphanedContracts=2`
- Act 4 (archive first): `RELOAD force=none`, Δ=1, `orphanedContracts=0`, `removeOld=DONE`
- Both acts: participant PID unchanged, Alice's party ID identical, ledger API still open

## PQS

`scripts/73-pqs.sh` at `harness-v26`, from a clean checkout. Logs: `pqs/20261027T090840Z/`, 25 runs,
all ending as expected (`summary.tsv`), with a `PROVENANCE.txt` recording tool versions, the PQS jar
hash and image digests. `pqs/README.md` states what every row shows and cites its logs; in short:

| Row | Claim | Result |
|---|---|---|
| `PQS-A` | Pruning archived history cleans PQS after a breaking reload | 3 reloads, 0 retired rows after each prune, PQS running throughout, about 0.3 s per reload |
| `PQS-B` | A reset with a version filter cleans PQS | **No.** PQS crashes on the replay: `key not found: (9644ff…,Mirrors,Mirror)` |
| `PQS-X` | Option B's remaining cases | A fresh database with the final filter crashes the same way; a reset after a prune undoes the prune |
| `PQS-D` | A fresh PQS re-ingest survives removal of the old DAR | **No.** With the DAR kept it catches up; after removal it loops on `No package for 9644ff…` and ingests nothing |
| `PQS-V` | The A, B and X results hold on PQS 3.5.1 and 3.6.2 | Identical measures; B crashes at the same step |
| `PQS-C` | A compatible reload needs PQS clean-up | **No.** PQS follows it by itself; old contracts stay under their original version |
| `PQS-M` | One prune covers a participant on two synchronizers | Yes; moves between synchronizers are not visible in PQS |
| `PQS-E` | The prune can run straight after the archive | **No.** It needs one later transaction |
| `PQS-I` | The prune covers interface views | Yes |
| `PQS-R` | A reset can keep the PQS database | **No.** A late restart on it runs silently with stale and missing rows; recreating it is correct in under a second |
| `PQS-S` | The prune scales | 50,000 archived contracts in 0.35 s of database time (0.49 s wall clock), readers not slowed |
| `PQS-L` | The reviewer's notes on Option A | The prune target rules hold; a repeat prune is a no-op; the filter restart changes nothing |
| `PQS-Q` | The prune works on CN QuickStart | Yes, per PQS database with its own offset. **Run on 2026-10-26, before `harness-v26`** (`pqs/20261026-quickstart/Q/`), because it needs a full LocalNet |

## What these runs do NOT establish

- **Participant pruning.** No run here touches it (pruning the PQS database is a separate operation, covered by the PQS rows). There is still no pruning script in the repo and
  `UNSAFE_TO_PRUNE` appears nowhere in the participant logs. The honest position remains
  "we did not test pruning", not "pruning did not work".
- **`repair.purge`.** Not re-run here and it has **no committed log**; the claim rests on a
  by-hand run against a Postgres sandbox that nothing in this repo can start. The script now sits
  in `console/historical/`.
- **Approach 1** (compatible version bump). `console/historical/upgrade-test.canton`, `forcebump.canton` and
  `upg2.canton` still load DARs from `/private/tmp` that do not exist, so that section of
  RESULTS.md is not reproducible and must be labelled historical until those fixtures are restored.
- **Multi-participant behaviour and in-flight submissions during the swap:** untested.
  Multi-synchronizer behaviour is covered for one participant by `MS1`, and PQS on that participant
  by `PQS-M`; several participants across several synchronizers are not. PQS is covered by the PQS
  rows, apart from the gaps listed in `pqs/README.md`.
- **Contract identities.** The loop archives and recreates contracts; only the participant process
  and the party IDs survive.
