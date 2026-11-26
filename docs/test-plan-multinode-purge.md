# Test plan: multi-node coordinated purge (rows MN0–MN6, PQS-P)

Prompted by daravep's review comment on canton-foundation/canton-dev-fund#937, line 59: archive does
not work on multi-node sandboxes. Fred should target 1 app-provider node + 1 app-user node + 2
synchronizers, delete contracts with the repair endpoint on every node, and coordinate it: sequencer
max-rate to 0, wait for pending transactions, purge on all nodes, restore the rate.

Design note §8 left the archive→swap window open for lack of a quiesce mechanism. These rows test
whether this is that mechanism. **No proposal text changes until these rows have logs.**

## Questions to answer

| # | Question | Why it matters |
|---|---|---|
| Q1 | In the reviewer's topology, where each party is hosted on exactly one participant, is there a single submission point with authority for both signatories of a two-signatory contract? If not, does a Daml-level archive fail, and with which error? Does it succeed once one participant also hosts the other party with submission rights? | Establishes the reason the `archive` hook doesn't carry over. It's about missing a single submission point with both parties' authority, not about multi-node in general. |
| Q2 | Which dynamic synchronizer parameter is the "max-rate" (expected: `confirmationRequestsMaxRate`)? Does setting it to 0 (a) reject new confirmation requests while (b) letting a request that was **already accepted and pending** complete? | This is the quiesce mechanism. Both halves need to be shown, with the error code a blocked submission gets. |
| Q2d | What bounded check proves that every accepted request has completed (committed or timed out) before purge? | A quiet ledger end isn't proof: a pending confirmation doesn't advance it. |
| Q3 | Do topology transactions (the vetting swap) still go through while the rate is 0? | If yes, the swap can happen inside the quiet window and the stranding window closes completely. |
| Q4 | Does `participant.repair.purge` on 3.5.12 work while connected, or does it require disconnecting from the synchronizer? | Decides whether the sequence has a disconnect/reconnect step. |
| Q5 | After purging on **every** stakeholder participant, do ACS commitments still match? After purging on **one** only, do they mismatch? | "Coordinated" is a correctness property. The one-sided purge is the control. |
| Q6 | Does the full sequence leave no contracts on the old package on either node, with both synchronizers swapped, no force flag, and a v2 choice working across both participants? | This is the headline result. |
| Q7 | If Fred dies while the rate is 0, can a resume read the checkpointed original rate and restore it? | Comment 4 (crash recovery) promises this. |
| Q8 | PQS: does a purged contract stay *active* in PQS (no archive event)? Which clean-up leaves PQS consistent and running? | Our M3 prune design assumes archive events. |

## Fixture (MN0)

- **Topology:** Canton 3.5.12 run directly from the dpm cache jar
  (`~/.dpm/cache/components/canton-open-source/3.5.12/lib/canton-open-source-3.5.12.jar`), new
  config `canton/multinode.conf`:
  - participants `provider` and `user`
  - synchronizers `syncA` and `syncB`, each with its own sequencer and mediator, in-memory storage
  - both participants connected to both synchronizers
  - a short ACS commitment reconciliation interval (a few seconds), so Q5 resolves quickly
  - short `confirmationResponseTimeout` and `mediatorReactionTimeout` (e.g. 10s each; check the
    3.5 parameter names), so the drain bound in Q2d is short
- **Model:** a new variant pair `variants/Shared.v1.daml` / `Shared.v2.daml`, with field type
  Text → Int as in Mirrors. It has a `Shared` template with `signatory provider, user` (created
  through a propose/accept pair, with a nonconsuming `Touch` choice controlled by `provider`) and a
  single-signatory `Own` template on each side.
- **Setup:** use find-or-create for parties: `Provider` is hosted on `provider` only and `User` on
  `user` only. Create 2 `Shared` (one per synchronizer) and 1 `Own` per party.
- **Asserted at fixture start:** the `PartyToParticipant` mappings on both synchronizers show each
  party hosted on exactly its own participant, and both participants are connected to both
  synchronizers. MN1's conclusion depends on this, so it is asserted, not assumed.
- **Driver:** `scripts/74-multinode.sh` plus `console/multinode.canton`, in the same assertion style
  as `72-multisync.sh` (an `ASSERT … PASS/FAIL` line per check, `EXPECT_CODE`, a `VERDICT` line,
  and non-zero exit on failure).
- **Repair commands:** already enabled console-side by `lib.sh` (`enable-repair-commands=yes`).

## Drain predicate (what Fred will use, tested in MN2)

After setting the rate to 0 on a synchronizer at time `T_rate0`, Fred treats that synchronizer as
drained when all of these hold:

1. **Time bound:** the synchronizer time has advanced past
   `T_rate0 + confirmationResponseTimeout + mediatorReactionTimeout + margin`. Both values are read
   from that synchronizer's dynamic parameters, not hard-coded. By protocol, any request that was
   accepted before `T_rate0` has a verdict (commit or timeout rejection) by then.
2. **Completions:** every submission Fred knows of on each participant (its own, and any the
   fixture issued) has a completion on the command-completion stream.
3. **Stability:** each participant's ledger end is unchanged across two probes spanning one
   reconciliation interval.

Condition 1 carries the guarantee. Conditions 2 and 3 are cross-checks that catch a wrong parameter
reading. If MN2 shows an accepted request completing *after* the time bound, the predicate is wrong
and this becomes a blocker (see Risks).

## Rows

| Row | What it does | Expected result |
|---|---|---|
| MN1 | Assert the hosting topology. From `provider`, submit `Archive` on a `Shared` with `actAs = [Provider, User]` | **Fails.** Record the exact error code (expected: an authorization/hosting error saying `provider` can't act for `User`). Conclusion, as worded in the log: "no single participant can submit with both signatories' authority in this topology". (Q1) |
| MN1b | **Comparison:** additionally host `User` on `provider` with submission permission (a `PartyToParticipant` change on both synchronizers), then repeat the archive on a fresh `Shared` | **Succeeds.** This shows MN1 fails for lack of a single submission point, not because the stakeholders are spread over several nodes. It also records a multi-hosting alternative, which we don't plan to use. Revert the hosting change before MN2 (or rebuild the fixture). (Q1) |
| MN2 | **Pending-request control:** disconnect `user` from `syncA`. From `provider`, submit `Touch` on the syncA `Shared` asynchronously. The sequencer accepts it, but it stays pending at the mediator because `user` can't confirm. Assert it's pending: no completion yet, and the request is visible as in-flight. Then set the rate to 0 on syncA and syncB, submit a new create (it must be **rejected**), and run a vetting topology change (it must **succeed**, Q3). Reconnect `user` within the timeout. Then evaluate the drain predicate and restore the rate | the pending `Touch` **completes successfully** after rate 0 is set and before the drain bound. The new create is rejected with a recorded code. The topology change goes through. All three predicate conditions hold. After the rate is restored, a new submission succeeds. (Q2, Q2d, Q3) |
| MN2t | **Timeout variant:** same as MN2, but leave `user` disconnected past the bound | the pending `Touch` gets a **timeout rejection** before the bound, and the predicate holds. This shows the bound covers both outcomes. (Q2d) |
| MN3 | Purge one `Own` while connected. If that fails: disconnect, purge, reconnect | record which works (Q4) |
| MN4 | **Control:** purge a `Shared` on `provider` only, then wait two commitment intervals | an ACS commitment mismatch is reported. Record how it surfaces (Q5) |
| MN5 | **Full coordinated sequence**, on a fresh fixture. Upload v2 unvetted on both nodes → rate 0 on both syncs → drain predicate holds on both → purge all v1 contracts on both nodes, per synchronizer (disconnecting if MN3 requires it) → swap v1→v2 on each node and each synchronizer, unforced, checking that the serial advances → restore the rate → setup on v2 → exercise a v2 choice on a `Shared` | zero v1 contracts on both nodes, v1 unvetted and v2 vetted everywhere, no force flag, no commitment mismatch after two intervals, the v2 choice succeeds. Time each step (Q5, Q6) |
| MN6 | **Crash test:** in the MN5 sequence, kill the console after the rate is 0 and before the purge. A fresh console reads the checkpoint file and restores the rate | the rate is back to its original value and the ledger is usable. Then rerun the sequence to completion (Q7) |

## PQS-P (Q8): isolated branches

Each clean-up option runs against its own database starting from the same state, so one branch can't
contaminate another.

1. **Capture.** Attach PQS to `provider` on database `pqs_live` (reuse `pqs/lib.sh`), run MN5 up to
   and including setup on v2, wait for PQS to pass the ledger end, then stop PQS. Record these
   baseline counts in `pqs_live`:
   - active v1 rows (expected > 0: the stale purged contracts)
   - active v2 rows
   - the checkpoint offset
2. **Snapshot.** Clone `pqs_live` into `pqs_a` with `createdb -T pqs_live`. Check with
   `pqs/compare.py` that the two databases are identical before anything changes.
3. **Branches:**
   - **(a) Row delete:** in `pqs_a`, delete the rows for the old package ids, then restart PQS on
     `pqs_a`.
   - **(b1) Full re-ingest:** start PQS on a fresh `pqs_b1` from genesis. The old DARs are kept.
     Purge removes contracts from the ACS but not from history, so the expected result is that
     re-ingest **reproduces** the stale active v1 rows. The row records whether that happens.
   - **(b2) ACS-based start:** start PQS on a fresh `pqs_b2` from the current ACS rather than
     genesis, if PQS 3.5 supports a ledger-start option for that.
4. **Postconditions for each branch, recorded independently:**
   - active v1 rows = 0
   - active v2 rows = the baseline
   - the history/creates counts, reported rather than asserted (they show what each option keeps)
   - the checkpoint advances past a new transaction issued after the branch finishes
   - re-ingest or restart completes without `No package` / crash lines in the PQS log
   - PQS is still running and ingests one further v2 create
5. **Result:** a table with one row per branch. Fred's M3 approach is the branch that meets every
   postcondition. If none does, the fallback is to reset PQS, which is recorded as such.

## Timing (after MN5 passes)

This uses the protocol of `scripts/80-timing.sh`, spelled out for the 2-node fixture:

- **Paths:** *reload* is the MN5 sequence from upload-unvetted to the v2 seeded state. *Restart*
  stops both participants and both synchronizers, starts them again, uploads and vets v2,
  re-runs setup and reaches the v2 seeded state.
- **Start event:** the moment the changed source is written (`logs/t0.source-write`, as in
  `05-variant.sh`).
- **End event:** an equivalent logical seeded state on both participants, checked by a 2-node
  `verify-seeded`. On the restart path the party ids may be new.
- **Reset:** every trial, warm-up included and on both paths, starts from a **freshly rebuilt**
  2-participant/2-synchronizer v1 fixture with fresh setup. The rebuild happens **outside** the
  timed interval. Nothing carries over between trials.
- **Direction:** always v1 → v2.
- **Order:** the paths alternate.
- **Warm-up:** the first trial of each path is discarded.
- **Samples:** 11 trials per path (1 warm-up + 10 measured). The log records the successful sample
  count per path. A failed trial is reported, not silently retried, and the comparison stands only if
  both paths have 10 successful measured trials.
- **Statistic:** the median per path, with min/max.

This replaces the single-node 40% figure for the new default topology.

## Outputs

- `evidence/<stamp>__MN__multinode.log`, `evidence/<stamp>__MN6__resume.log` and the PQS-P logs under
  `evidence/pqs/`.
- MN rows in `evidence/INDEX.md`, and a design-note §8 update (quiesce mechanism and drain
  predicate) once the logs exist.
- Provenance: the harness voids on a dirty tree. Commit the new scripts, tag `harness-v28`, then
  produce the citable runs. Exploratory runs before that are fine but not citable.
- Not in scope here: proposal text edits for comment 1. They follow from these results.

## Risks / fallbacks

- **Rate 0 doesn't block, or blocks topology too:** fall back to the existing idle detection plus
  disconnecting the participants during the purge, and say so.
- **A request can't be held observably pending by disconnecting `user`** (e.g. the submission is
  rejected up front): fall back to pausing `user`'s confirmations another way, such as a mediator
  or participant delay if 3.5 has a test hook for it. If nothing works, report Q2(b) as
  untested.
- **An accepted request completes after the time bound:** the drain predicate is unsound. This is a
  blocker; raise it with daravep before changing the proposal.
- **Purge needs a disconnect:** the sequence gains disconnect/reconnect per node. The rate-0 step is
  still needed so the other node doesn't submit while one is disconnected.
- **Commitments mismatch even with a coordinated purge:** this would be a blocker. Raise it with
  daravep before changing the proposal.
- **Only synchronizer owners can change the rate:** fine on sandbox and LocalNet, but not on shared
  DevNet synchronizers. That becomes the documented boundary.

## Review issues addressed

- **Drain not demonstrated (MN2/MN5):** accepted. MN2 now holds a `Touch` pending before rate 0 by
  disconnecting `user`, asserts that it's pending, and shows it completing while a new create is
  rejected. MN2t shows the timeout outcome. I added an explicit **drain predicate**: a protocol time
  bound from the synchronizer's dynamic `confirmationResponseTimeout + mediatorReactionTimeout`,
  with completions and ledger-end stability as cross-checks. MN5 uses that predicate instead of
  "ledger end is stable". An accepted request completing after the bound is listed as a blocker.
- **Q1 overstated:** accepted. Q1 is reworded to "no single submission point with authority for
  both signatories in this topology". The hosting topology is asserted at fixture start, the exact
  error code is recorded, and MN1b adds the comparison topology (`User` also hosted on `provider`)
  that separates the narrow claim from the broad one.
- **PQS branches contaminating each other:** accepted. The ledger state is captured once in
  `pqs_live`, and (a) runs on an identical clone checked with `compare.py`. (b1) and (b2) each get a
  fresh database. Each branch has its own postconditions (active/history counts, checkpoint
  progress, restart/re-ingest completion, continued operation). I added the expectation that a full
  re-ingest reproduces the stale rows, since purge leaves creates without archives in history.
- **Timing contract omitted:** accepted. The section now spells out start/end events, a fresh
  rebuilt v1 fixture per trial outside the timed interval (warm-ups included), alternation,
  discarding the first trial, 10 measured trials per path, the successful-sample count in the log,
  and comparing only if both paths have 10 successes.

## Results (2026-11-26, Canton 3.5.12, exploratory: not yet committed or tagged)

All rows ran on AC power with no machine sleep (checked against `pmset -g log`). Runs made while the
machine slept were discarded. Logs are under `logs/` (gitignored) until the harness is committed and
tagged and the citable runs go to `evidence/`.

| Q | Row | Repeats | Result |
|---|---|---|---|
| Q1 | MN1/MN1b | 3/3 | No single participant can submit for both signatories: `NO_SYNCHRONIZER_ON_WHICH_ALL_SUBMITTERS_CAN_SUBMIT`. Acting as one signatory gives `DAML_AUTHORIZATION_ERROR`. With `User` also hosted on `provider` (Submission), the archive succeeds. |
| Q2 | MN2 | 3/3 | `confirmationRequestsMaxRate = 0` rejects new submissions at the sequencer: `SEQUENCER_OVERLOADED` ("rate limit of 0/s"). A request accepted **before** rate 0 still **commits** (0.8s after rate 0, once its confirmer reconnects). |
| Q2d | MN2t | 3/3 | With the confirmer kept away, the pending request is rejected with `MEDIATOR_SAYS_TX_TIMED_OUT` (unresponsive party `User`) inside the bound. **Ledger end is not a valid stability signal**: it keeps advancing at rate 0 with no transaction indexed (rejections/topology). The drain cross-check is ACS stability, which held in every run. |
| Q3 | MN2 | 3/3 | A v1→v2 vetting swap succeeds at rate 0 and the serial advances. Topology is not rate-limited, so the swap runs inside the quiet window. |
| Q4 | MN3 | 3/3 | `repair.purge` needs the participant disconnected from **every** synchronizer (`CONTRACT_PURGE_ERROR: There are still synchronizers connected`). It also refuses in-memory storage ("Use db persistence"), so participants must be DB-backed (H2 used here). The default in-memory `dpm sandbox` cannot be purged. |
| Q5 | MN4 | 3/3 | Control: purging on one participant only gives `ACS_COMMITMENT_MISMATCH` within one 5s reconciliation interval. |
| Q6 | MN5 | 3/3 | The full sequence (rate 0 → drain → per node: disconnect all, purge, reconnect → 4 unforced swaps, serial +1 each → restore → setup v2 → v2 choice across nodes) passes with no commitment mismatch over 5 intervals. |
| Q7 | MN6 | 2/2 | Fred is `kill -9`ed after quiesce. The network stays at rate 0 (submissions blocked) and v1 is untouched. A fresh console restores the rates **from the checkpoint**, the ledger is usable again, and the full reload then completes. |
| Q8 | PQS-P | 2/2 | **The expectation was wrong.** Purge reaches PQS as an archive: after the purge PQS shows 0 active v1 contracts, and the v1 rows remain as archived history. The existing M3 design applies unchanged: `prune_archived_to_offset` removes the v1 history (5 → 0), v2 is untouched, and PQS keeps running and ingesting. A fresh re-ingest from Oldest and a start from Latest both end with 0 active v1 contracts. The row delete (a) found nothing to delete. |

### Timing (10 measured trials per path, 1 warm-up discarded, alternating, fresh v1 fixture per trial)

| Synchronizer timeouts | Reload median (min–max) | Restart median (min–max) |
|---|---|---|
| confirm 30s / mediator 10s | 60.4s (60.1–61.1) | 17.9s (17.1–18.3) |
| confirm 5s / mediator 5s | 30.1s (29.6–31.5) | 19.3s (17.2–25.4) |

- **Reload:** the drain wait (confirm + mediator + 5s margin + 6s ACS probe) is 51.4s and 21.2s. Every other step totals about 4s, and the per-reload console JVM adds about 5s.
- **Restart:** about 2.5s to build and stop, and about 15s to start a bare Canton 2-node topology and seed it.
- **On this bare topology the coordinated reload is slower than a restart**, because the drain must cover the worst case. The reload can only win where a restart is expensive (LocalNet / CN QuickStart: 129s plus onboarding), and that is not measured here.

## LocalNet (CN QuickStart `8b898ed`, Splice 0.6.11), 2026-11-26

Run against LocalNet only (`make start-localnet`): one synchronizer (`global`), app-provider (aprov) and app-user
(auser) participants on Postgres, consoles started on the `localnet` docker network (`localnet/ln-run.sh`,
`localnet/ln-lib.canton`). Functional rows LN0–LN2 were first run on battery; all timing below (LN3) was re-run on
**AC power** with the repeated-trial protocol. Docker logs were capped for the timed runs (`localnet/ln-logcap.yaml`,
3 × 200 MB per container); log level and app config are LocalNet's defaults.

| Row | Result |
|---|---|
| LN0 ownership | The synchronizer is owned by a decentralized namespace with threshold 1 whose only owner is the **SV participant**. The sequencer and the app participants have their own namespaces. A developer can change dynamic synchronizer parameters on LocalNet only through the SV participant's admin API (unauthenticated on LocalNet). |
| LN0 rate 0 | `confirmationRequestsMaxRate = 0` proposed from the SV participant takes effect and **is not reverted by the SV app** (held 190s, twice). Defaults: confirm 30s, mediator reaction 30s, reconciliation 30 min. |
| LN0 params the SV app enforces | `reconciliationInterval` set to 10s from the SV participant is **reset to 30m by the SV app within ~10s**. Confirm/mediator timeouts (5s/5s) and the max rate are left alone. So on LocalNet ACS commitments are only exchanged at the 30-minute ticks (:00, :30), and each participant delays sending by a random amount (observed up to ~20 min) before they are compared. |
| LN1 | Coordinated reload v1 → v2, then v2 → v1, across aprov and auser: **PASS** in both directions. Rate restored from the checkpoint each time, the old package unvetted, no contracts left on it, parties unchanged. Purge works on LocalNet's Postgres participants with `disconnect_all` / `reconnect_all`. |
| LN2 dev-tuned | Confirm 5s / mediator reaction 5s proposed from the SV participant take effect and hold (checked after 60s and through 11 trials). LN1 at 5s/5s: **PASS** both directions. |
| Setup on LocalNet | Needs more than bare Canton: the dev ledger user (`ledger-api-user`) must be granted act/read rights on the parties it allocates, submissions must name that user id, and the console needs read-any-party because it reads each transaction for every hosted party (DSO included). Find-or-create plus grant-rights is the setup pattern. |
| LN4 Splice side effects | During rate 0 the Splice apps' own submissions are rejected with `SEQUENCER_BACKPRESSURE` / `SEQUENCER_OVERLOADED`: a 190s rate-0 hold gave 2 (SV status report); a reload at default timeouts (71s window) gave ~20 (validator treasury / traffic top-up, faucet coupon), and the **treasury circuit breaker tripped** (WARN). All are retried; the breaker went half-open at 14:10:07 and **closed at 14:10:11, ~50s after the reload ended**; no further WARN/ERROR afterwards. At 5s/5s (~25s windows) nothing was rejected. Harmless on LocalNet, but the rate-0 window is visible to Splice automation. |
| LN5 commitments after reload | Fresh LocalNet, coordinated reload v1 → v2 at 14:07–14:09, then the 14:00–14:30 commitment period checked with `commitments.lookup_sent/received_acs_commitments`: **Match** on every link (aprov↔auser, aprov↔SV, auser↔SV), received by 14:52. |
| LN6 commitments control | One-sided purge (v2 contracts purged on aprov only, 13:56): the 13:30–14:00 period shows **Mismatch** for aprov↔auser and Match for each with SV. The check detects a bad purge on LocalNet. (The `ACS_COMMITMENT_MISMATCH` log line was not found because the capped logs had rotated; the lookup API is the reliable check.) |
| Note | The SV app's `ReconcileSequencingParametersTrigger` runs in a tight loop on LocalNet (~60k "Updated sequencing parameters" per 15 min), a large part of the log volume that filled the disk earlier. Not caused by Fred. |

### LN3 timing on LocalNet (AC power; 1 warm-up discarded + 10 measured per path; alternating; fresh LocalNet + v1 fixture per trial)

Same protocol as bare-Canton timing (`scripts/77-mn-timing.sh`), runner `localnet/ln-timing.sh`. T0 = v2 source written;
both paths include the `dpm build` (~2s); end = v2 seeded (2 Shared + 1 Own per party) on both app nodes.
Restart = `make clean-localnet` + `make start-localnet` + parties, rights, upload + vet v2, seed. Reload = fresh console JVM
running the coordinated reload. All 33 trials passed, none failed. Raw rows: `logs/ln-timing-{default,devtuned}/trials.tsv`.

| Timeouts (confirm / mediator) | Reload median (min–max) | Restart median (min–max) |
|---|---|---|
| 30s / 30s (LocalNet default) | **88.1s** (87.5–89.0) | **110.1s** (109.4–130.8) |
| 5s / 5s (set from SV participant) | **37.3s** (37.0–38.5) | not re-run (restart does not depend on these timeouts) |

- **Reload, default:** drain 71.2s (30 + 30 + 5s margin + 6s ACS probe), quiesce 1.7s, purge 0.8s, swap 1.2s, restore 0.5s,
  setup 2.8s, build 2.1s, console JVM start/exit ≈ 7.8s.
- **Reload, 5s/5s:** drain 21.2s; everything else as above.
- **Restart:** build 2.2s, stop 4.5s, **start 88.8s** (8 of 10 trials; 2 took ~109s, LocalNet health-check timing), setup 14.1s.
- **On LocalNet the coordinated reload beats a restart** (88s vs 110s at defaults, 37s vs 110s at 5s/5s), the reverse of the
  bare 2-node topology, because a LocalNet restart is expensive. The drain is the reload's whole cost; lowering the timeouts is
  what makes it ~3× faster than a restart.
- The proposal's 129s restart figure (start 120s + stop 9s, 2026-09-28) is close to the slow trials here; the median start is 88.8s.
