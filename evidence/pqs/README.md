# PQS evidence

What a reload does to the Participant Query Store (PQS), and which clean-up works. A breaking reload
archives the old contracts, and PQS keeps them as archived history next to the new rows. Two ways to
remove that history were compared:

- **Option A, prune:** `prune_archived_to_offset` up to the last archive, with PQS running.
- **Option B, reset and filter:** stop PQS, `reset_to_offset` to before the old version, restart it
  with a version filter that excludes the old version, and let it replay.

**Result: Option A works in every configuration tested. Option B crashes PQS whenever the versions
share a package name, which is Fred's normal case.**

## Runs

`20261027T090840Z/` was produced by `scripts/73-pqs.sh` at `harness-v26`, from a clean checkout
(`PROVENANCE.txt`: tool versions, PQS jar hash, image digests, fixture hash). All 25 runs ended as
expected (`summary.tsv`), over 1,280 recorded steps. Each run directory holds numbered logs for
every console, SQL and PQS step, plus `steps.tsv` (each step with its expected and actual outcome),
`offsets.tsv` and `measures.tsv`.

Environment: Canton 3.5.12 (`dpm sandbox`), PQS 3.5.7 (`--pipeline-ledger-start Oldest`, all
parties) unless a row says otherwise, Postgres 16. Fixtures: `pqs/fixtures/` (four breaking
generations of `mirrors`, Text → Int → Bool → Decimal, each pinned by package id in
`fixtures.tsv`). Every ledger also carries an unrelated `Items` anchor (stays active) and collateral
(archived at once), to measure collateral damage.

`20261026-quickstart/Q/` is the CN QuickStart row. It ran on 2026-10-26, **before** `harness-v26`,
with `pqs/quickstart/` as committed apart from two path lines (`QS_DIR`, `PQS_LOGROOT`). It is not
re-run at the tag because it needs a full LocalNet; treat it as supporting evidence, not as a tagged
run.

## Results

| Row | Run | What it shows | Evidence |
|---|---|---|---|
| **PQS-A** | `A` | **Option A is correct across three breaking reloads.** Before each prune the 2 retired rows sit beside the 2 current ones; after it, 0 retired and 2 current, with the anchor kept. PQS reloads each new package by itself and runs throughout. About 0.3 s per reload (dry run plus prune, wall clock). A fresh re-ingest brings all 6 retired rows back, and one prune to the last boundary removes them again. The CLI prune (`--postgres-*` flags) gives the same result as SQL. | `A/measures.tsv`, `A/04-pqs-start-adb.log`, `A/*-prune.log` |
| **PQS-B** | `B` | **Option B crashes PQS on the first reload.** After the reset, the filtered replay delivers the excluded version's events and PQS stops: `NoSuchElementException: key not found: (9644ff…,Mirrors,Mirror)`. PQS subscribes by package *name* (`#mirrors`), so Canton streams every version, and the filter only removes versions from PQS's own decoders. The procedure also locks readers out while PQS is down. | `B/39-pqs-start-bdb.log`, `B/27-g2-terminate.log`, `B/28-g2-reader-refused.log` |
| **PQS-X** | `X` | The Option B cases the crashed run cannot reach. A fresh database with the final filter crashes the same way. A reset below the pruning marker is accepted and moves the marker back, and an unfiltered replay then re-ingests everything the prune removed. A reset below the oldest history is refused. A reset after a prune can resolve far below the requested offset. | `X/measures.tsv` |
| **PQS-D** | `D` | **Removing the old DAR breaks a fresh PQS re-ingest.** Same ledger, two fresh databases: with the old DAR kept, PQS catches up with the full history (g1 history 2, g2 active 2). After `dars.remove`, PQS loops on `UnknownDamlPackageException: No package for 9644ff…` and ingests nothing. The participant still serves the events; PQS cannot decode them. So Fred keeps old DARs while PQS is attached. | `D/measures.tsv`, `D/*pqs-start-ddb_removed.log` |
| **PQS-V** | `A351` `B351` `X351` `A362` `B362` `X362` | **The same on PQS 3.5.1 and 3.6.2** (DA's images), against the same sandbox: every A and X measure identical, B crashes at the same step with the same error. | `*/measures.tsv`, `B351/39-pqs-start-bdb.log`, `B362/39-pqs-start-bdb.log` |
| **PQS-C** | `C` `CT` | **A compatible (SCU) reload needs no clean-up.** Two compatible upgrades (1.0.0 → 1.0.1 → 1.0.2), uploaded and vetted normally, nothing archived. PQS loads each version without a restart. Old contracts stay active under their original version and payload shape (no key for the new field); a choice used on an old contract through the new version is recorded under the new version. The prune never removes active contracts of any version, and a fresh re-ingest gives the identical active set. `CT` repeats it with `TransactionTreeStream`, the only datasource that records exercises. | `C/measures.tsv`, `C/q6.diff`, `CT/snap-*.tsv` |
| **PQS-M** | `M` `MP` | **One participant on two synchronizers:** one prune clears the retired rows from both (4 → 0, in 0.26 s), and a fresh re-ingest of the two-synchronizer history works. PQS does not see moves between synchronizers (a contract left mid-move still shows as active), so in-flight moves must be found through the Ledger API, as in `MS1`. `MP` repeats it with PQS restricted to one party: identical results, but a party added later is not picked up, and adding it on restart does not backfill its earlier contracts. | `M/measures.tsv`, `MP/measures.tsv` |
| **PQS-E** | `E` | **The prune needs one transaction after the archive.** With nothing created after the reload, the prune is refused ("beyond upper bounds of contiguous history") and the old rows stay. Once a later transaction exists, the same prune succeeds. In all-parties mode, a party allocated after PQS started is picked up without a restart. | `E/measures.tsv` |
| **PQS-I** | `I` | **Interfaces:** a template implementing an interface from a package that is never reloaded. PQS adds the interface by itself ("8 templates and 1 interfaces"), and the prune clears the interface view's history as well (creates 4 → 2, active unchanged). | `I/measures.tsv` |
| **PQS-R** | `R-live` `R-restart` `R-late` `R-fresh` | **A Fred reset must recreate the PQS database.** Kept on its old database, PQS either exits ("Requested start '110' is outside of ledger history"), or, if restarted after the new ledger has passed its old checkpoint (`R-late`), runs with no warning while holding all 32 stale rows and only 10 of the 42 new contracts, at checkpoint 140 against ledger end 142. Recreating the database (`R-fresh`) is correct: 0.9 s to recreate, all 42 contracts correct 6.8 s after PQS starts. A check for PQS rows belonging to parties the participant does not know catches every stale state; "checkpoint beyond ledger end" does not. | `R-*/measures.tsv`, `R-late/*pqs-start*.log` |
| **PQS-S** | `S-1000` `S-10000` `S-50000` | **The prune scales.** Table below. 1,000 active Items survive every prune, PQS stays up and ingests the probe transactions that follow, and readers are not slowed. | `S-*/measures.tsv`, `S-*/analysis.txt` |
| **PQS-L** | `L-filter` `L-nofilter` | **The reviewer's notes on Option A.** A prune to PQS's latest checkpoint is refused ("coincides with latest consistent checkpoint"), and one to the ledger end is refused ("beyond upper bounds"). One to just below it only removes part of the history, and the archive offset itself is accepted once one later transaction exists. A repeat prune is a no-op with a warning. Restarting PQS with the version filter after the prune works, but changes nothing: every measure is identical to the matched run without the filter. | `L-*/measures.tsv`, `L-compare.txt` |
| **PQS-Q** | `20261026-quickstart/Q` | **CN QuickStart** (Splice 0.6.11, PQS 3.5.4, OAuth2 through Keycloak, one single-party PQS per participant): the prune works per PQS database, each with its own participant's offset (retired 3 → 0 and 2 → 0, current 2 kept, about 0.5 s, PQS running, 0 restarts). It also removes QuickStart's own archived history up to that offset. The first app-user attempt failed when Canton ran out of memory and was rerun; its log is kept. | `Q/measures.tsv`, `Q/steps.tsv`, `Q/13-app-user-init.canton-oom.log` |

### Prune at scale

| Archived contracts | 1,000 | 10,000 | 50,000 |
|---|---|---|---|
| PQS rows before (contracts / events / transactions) | 2,004 / 3,005 / 125 | 11,004 / 21,005 / 845 | 51,004 / 101,005 / 4,045 |
| Dry run, database ms (wall) | 6.4 (108) | 17.8 (116) | 175.8 (301) |
| **Prune, database ms (wall)** | **9.5 (106)** | **58.0 (169)** | **347.0 (492)** |
| Rows after (contracts / events / transactions) | 1,023 / 1,023 / 63 | same | same |
| Database size before → after (no `VACUUM`) | 14 → 15 MB | 29 → 30 MB | 87 → 73 MB |

Reader queries that overlapped the prune finished in at most 1.4 ms, no slower than before it. The
space is reused inside Postgres but not returned to the operating system without `VACUUM`.

## What Fred does with PQS, from these results

- Start PQS with `--pipeline-ledger-start Oldest` (or `Latest`).
- Keep old DARs while PQS is attached (`PQS-D`).
- After a breaking reload: record the offset of the last archive transaction, wait until PQS has
  passed it, dry-run, then `prune_archived_to_offset` to it. The prune follows the archive
  confirmation policy, since it removes all archived history up to that offset, and a retry is a
  no-op (`PQS-A`, `PQS-E`, `PQS-L`).
- After a compatible reload: nothing (`PQS-C`).
- On a Fred reset: drop and recreate the PQS database, and before reporting "synchronised" check that
  PQS holds no rows for parties the participant does not know (`PQS-R`).
- On several synchronizers: the same single prune; in-flight moves are checked on the Ledger API
  (`PQS-M`).
- On QuickStart and LocalNet: prune each PQS database with its own participant's offset (`PQS-Q`).

## Not covered

- Whether PQS ingests *during* a prune: the prune finished before the first probe transaction
  arrived, at every scale.
- A Fred reset on QuickStart (re-onboarding parties and re-granting PQS rights).
- `--pipeline-ledger-start Genesis` breaking PQS's automatic package reload, and the command line
  truncating `--pipeline-filter-contracts` values that contain `=`: both seen in earlier by-hand
  probes, with no committed log.
