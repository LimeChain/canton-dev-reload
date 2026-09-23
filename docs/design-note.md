# Design note — `dpm dev-reload`

Specifies the reload core, the baseline lifecycle and the hook contract, which is what the
`fred reload` fallback path runs. The supervisor layer described in
[`proposals/2026-09-LimeChain-FRED-v3.md`](../proposals/2026-09-LimeChain-FRED-v3.md), which starts
the sandbox and watches for rebuilt DARs, is not specified here yet.

**Status: design, not implementation.** Nothing here exists yet — Milestone 1 builds it. The
evidence in this repository establishes that the underlying *sequence* works; it does not establish
that this interface is the right one. Where this note asserts a Canton behaviour, it cites the
evidence row that shows it; where it does not cite one, it is a design decision open to revision.

---

## 1. Why an interface is needed at all

The reload primitive is generic: archive → upload unvetted → one `propose_delta` → reseed. The
**contract lifecycle around it is not**. A component cannot know which contracts matter to a
project, cannot infer a `Text` → `Int` migration, and cannot recreate application data.

The proof of concept sidesteps this by hardcoding everything: `seed/daml/Seed.daml` queries
`@Mirror`, creates `Mirror`, and allocates parties by the literal hints `"Alice"` and `"Bob"`. That
is fine for a proof and useless as a product. The interface below is what replaces it.

## 2. The configuration file

```yaml
# dev-reload.yaml — at the project root, beside daml.yaml or multi-package.yaml
script-package: seed          # the Daml Script package providing the hooks

hooks:
  discover: Seed:discover     # -> contracts in scope, with their required signatories
  archive:  Seed:cleanup      # archives them, as their signatories
  reseed:   Seed:seed         # recreates working state after the swap
  verify:   Seed:verify       # optional postcondition, checked before the baseline advances
```

**Hooks are Daml Script, not plugin code.** Three reasons. The project already has a script package;
that package already holds the signatory authority the technique depends on, because the developer
allocated the parties; and `dpm script --upload-dar` defaults to false, so the script package stays
out of the vetting set and is never part of the closure being swapped — though it *is* compiled
against the model and must be rebuilt when the model changes.

**The component never infers a migration.** If the new schema needs data the old shape cannot
supply, that is `reseed`'s problem and the developer's decision. Automatic schema migration is
explicitly out of scope.

## 3. The old/new boundary, and why a baseline is required

`archive` must run against the **old** packages — it queries contracts of the old shape — while
`reseed` must run against the **new** ones. Once the developer edits the source, the old hook can no
longer be built.

The proof of concept solves this by hand, keeping a copy: `scripts/70-matrix.sh:59` preserves
`artifacts/mirrors-seed-v1.dar` before the v2 build overwrites it, and
`scripts/71-closure.sh` does the same with `seedab-v1.dar`. A product cannot rely on the developer
remembering to do that.

So the component owns a **baseline**:

- **`dpm dev-reload init`** captures the last-known-good closure — every model DAR *and* the built
  script-package DAR — into a component-managed directory, recording each package id.
- **Each reload** resolves `discover` and `archive` from the *baseline* build, and `reseed` and
  `verify` from the *new* build. One source package, two builds, selected by phase.
- **The baseline advances only after step 9 verifies** (below) — not after the swap, and not
  optimistically. A failed reload leaves the baseline describing what is actually on the ledger.
- **With no baseline the tool refuses** and names `init` as the remedy. Once the source has been
  edited there is nothing to build the old hook from, and guessing is worse than stopping.

## 4. Authority is per contract, not per declared party

Checking that the declared parties are locally allocated does **not** establish authority over every
discovered contract. A contract may carry an undeclared or jointly-controlled signatory, and the
archive hook would then fail partway — after earlier contracts had already been consumed, with no
way back.

`discover` therefore returns contract ids **with their required signatories**, and the component
verifies it can act for every one of them across the whole discovered set *before* archiving
anything. If the set is incomplete it refuses, naming the contracts and the missing parties.

*Open:* whether per-contract signatories are readable directly from the 3.5.12 admin ACS, or whether
`discover` must report them itself. Both are viable; the second is assumed here because it needs no
API guarantee.

## 5. Ordering is a correctness property

Archival is irreversible. A naive implementation archives and then does build, upload, topology and
reseed — any of which can fail, leaving a developer with destroyed state and no reload. So every
fallible step happens first:

```
PREFLIGHT  (nothing destructive; abort freely)
  1. build the closure and the script package; classify the change via dpm upgrade-check
     -> if it is a valid upgrade, tell the developer to bump the version and STOP
  2. upload every DAR unvetted; verify each package id is present
  3. verify environment: no peers on the synchronizer; baseline exists; participant idle
  4. resolve hooks; run discover; verify actAs for every required signatory
  5. read and record the synchronizer-store VettedPackages serial
COMMIT  (destructive; from here, resume rather than restart)
  6. archive          <- irreversible, and now preceded by nothing that can fail
  7. propose_delta    <- assert the serial advanced from (5)
  8. reseed
  9. verify, then advance the baseline
 10. dars.remove(old) <- optional
```

**Step 10 is conditional when PQS is attached.** Removing the old DAR leaves history that references
it unreadable, which breaks a PQS re-ingest. While PQS is configured the old DARs are retained for the
life of the session. Unvetted packages cannot be submitted against, so retention costs nothing.

Two details in that sequence are load-bearing, and both are evidenced:

- **Step 7 targets the synchronizer store.** `propose_delta` defaults to the *Authorized* store,
  which on a fresh participant holds no `VettedPackages` mapping — so a defaulted call computes a
  delta against nothing, emits serial 1, changes nothing, and **returns success**. Asserting the
  serial advanced is what makes that detectable. Our own first run was a false positive for exactly
  this reason.
- **Step 6 precedes step 7.** After the swap the old package is unvetted and nothing from it can be
  exercised, `Archive` included — so contracts archived afterwards are stranded permanently.
  Evidence: `STORY` Act 3 (`orphanedContracts=2`) against Act 4 (`orphanedContracts=0`).

## 6. Idempotency is a hook contract

A Daml Script hook contains multiple submissions, so it can fail part-way. Therefore:

- **`archive` must converge** — re-running drives the discovered set to zero, so a mid-archive
  failure is recoverable by re-running. Query-then-archive satisfies this.
- **`reseed` must not duplicate** — it must query before creating, the way `getOrAllocate` in
  `seed/daml/Seed.daml` already does for parties.

**Neither can be verified on the developer's live ledger**, and the component must not pretend
otherwise: running `reseed` twice *is* a mutation, and proving `archive` converges would destroy the
state being protected. `dev-reload check` validates both in a **throwaway sandbox** instead —
destructive by design on a ledger that is discarded, and re-runnable against the new build after an
edit.

Worth noting that the proof of concept's own example fails this contract: `Seed:cleanup` is
re-runnable, but `Seed:seed` does a blind `createCmd` per party and duplicates on re-run. Fixing it
is part of Milestone 1.

Durable per-phase checkpoints (`archived` / `swapped` / `reseeded`) let a resumed run re-enter at
the right step rather than restarting.

**Why not an append-only log of what has been archived?** Because a local list must not be the
authority for a retry. What makes `archive` re-runnable is current state, not history: `discover`
re-queries the active set, so after a partial archive it returns exactly what remains and re-running
converges to zero. A component-side "already archived" list is a second claim about that same state
and can disagree with it in either direction, a submission that committed after the local write
failed, or a local write that landed for a submission that did not. Resolving the disagreement means
querying the ledger again, which is what the hook already does.

The ledger is not a durable substitute for forensic history either: a participant can be pruned,
after which it retains a state snapshot and can no longer serve the preceding events. So current
state is authoritative for **convergence**, while **"what did this run destroy?"** has no
authoritative answer here at all, and §5 opens by saying archival is irreversible.

**Optional, not required by Milestone 1.** The durable checkpoint store could carry a run journal
beside the phase name: the set `discover` returned, the vetted package ids added and removed, the
synchronizer serial before and after, and the phase reached. Those are facts the orchestrator already
holds. It could **not** record what `reseed` created, since `reseed` is an arbitrary Daml Script hook
with no declared result and this design neither brackets ledger offsets nor consumes the update
stream, nor state precisely which contracts a mid-hook failure archived, which is resolved by
re-running `discover`. Recording more than that needs an offset-bracketing design and a
reconciliation rule for uncertain submissions; neither is specified here.

## 7. What `verify` means

Step 9 is the only thing that advances the baseline. It requires **all** of:

- **Built-in postconditions**, always checked: zero active contracts on any old package id; every
  declared party resolving to the same party id as before; the effective vetted set containing every
  new package id and no old one.
- **The project's `verify` hook**, if declared — the component cannot know what "seeded correctly"
  means for someone else's model.

If `verify` is omitted, only the built-ins apply, and the documentation must say the baseline then
advances on a weaker guarantee.

## 8. Concurrency: scoped, not claimed

Between archive completing and the swap landing there is a window in which a running application
could create a contract on the old package and strand it. **We have not verified a supported
mechanism to block submissions for that window, so the tool does not claim one.**

Milestone 1 is scoped to a participant the tool has **detected idle** — the component probes the
ledger end over an interval and refuses if the offset is advancing. A user's assurance is not a
precondition; a detected one is. Post-swap detection of a stranded contract is **damage reporting,
not a safety guarantee**, and the documentation must say so in those words. Running an application
against the ledger during a reload is outside the supported envelope.

Closing the window outright needs a supported quiesce mechanism. That is a question for Digital
Asset, and a follow-on if the answer is yes — not an M1 promise.

## 9. Evidence map

| Design decision | Evidenced by |
|---|---|
| The swap needs no force flag | `E1`, gated by `C1`/`C2`, corroborated by `E3` |
| It works with live contracts too, but strands them | `E2` |
| Unvetting with live contracts succeeds unforced | `E4`, `E5` |
| The result is deterministic | `E6r1`–`E6r3` |
| A dependent that is not rebuilt breaks | `M1` |
| The whole closure swaps in one transaction | `M2` |
| Party IDs survive; ordering decides stranding | `STORY` |
| The loop is faster than restarting | `TIMING` |

Rows resolve in [`../evidence/INDEX.md`](../evidence/INDEX.md).

**Not evidenced, and therefore design only:** everything in §2, §3, §4, §6 and §7 — the hook
interface, the baseline lifecycle, per-contract authority, the idempotency contract and the verify
semantics. Those are what Milestone 1 builds and proves.
