# Internal dry run — prep notes

For presenting to colleagues **before** the Canton meeting. Goal: pressure-test the argument
and find the questions you cannot answer yet.

~20 minutes: 5 background, 3 demo, 6 findings, 6 discussion.

---

## Part 0 — five things you must explain cold

**1. A package's identity is a hash of its code.** Change one character and you get a package
with a different ID. Canton has no concept of "the same package, edited" — those are two
unrelated packages that happen to share a name.

```
mirrors 1.0.0  c17b5cb16a9d..   value : Text
mirrors 1.0.0  dba33b18bff3..   value : Int
```

**2. Vetting is an allowlist. Uploading code is not the same as allowing it to run.** A
participant can hold a package without vetting it. Vetting is a signed *topology transaction*
saying "I will process transactions using these packages." Editing that list is normal and
supported. This is the concept people miss, and the one that makes everything possible.

**3. Packages and contracts are different things with different vocabularies.**

| | State words | Deletable? |
|---|---|---|
| **package** (the code) | vetted / not vetted | yes — `dars.remove` |
| **contract** (the data) | active / archived | archiving removes it from the active set; the history record stays |

"Archived" never applies to a package. "Unvetted" never applies to a contract. Getting this
wrong is the single most common confusion — including ours, early on.

**4. Smart Contract Upgrades resolve templates by package *name*, not ID.** That is what lets an
app keep working when you ship 1.0.1. Two consequences:
  - Canton refuses to vet two packages with the same name **and** version — "which `Mirror`?"
    would have no answer.
  - A dependent package **follows** an upgrade automatically. We proved this: after upgrading A
    to 1.0.1, package B — never rebuilt — kept fetching from A, and a script built against
    A 1.0.0 created new contracts at 1.0.1 on its own.

**5. Upgrade checks exist for a real reason.** In production you must not end up with data
written by code a later version cannot read. We are not arguing against that — we are arguing
it does nothing useful in a loop where you *want* to discard the data.

---

## Part 1 — the problem (2 min)

> "You have a participant running with parties allocated, test data seeded, and an app
> connected. You change one line of a template. Today you either bump the version and write an
> upgrade — which fails, because most edits you make while developing are not valid upgrades —
> or you restart and lose everything."

Pre-empt the obvious objection — *"just restart, it's a dev box"*. Act 2 of the demo answers it:
party IDs are **not stable** across restarts, so it is not merely data loss; every connected app
has to reconnect and re-resolve who it is talking to.

## Part 2 — the demo (3 min)

`bash scripts/60-story.sh --live` — you hand-edit one line, `type Val = Text` → `type Val = Int`.

- **Act 1** — upload it. Canton rejects it. Real error, not a slide.
- **Act 2** — so you restart, and lose every party and contract; the new Alice has a different ID.
- **Act 3** — the same rejected package goes in via the reload. Same PID, same party IDs,
  incompatible model live.

## Part 3 — what we found (6 min)

Lead with the fact that we set out to ask Canton for a new operation and **no longer are.**

**There are two approaches, and which you need depends only on whether your change is a valid
upgrade.**

**Approach 1 — compatible change: bump the version.** Already fully supported. Works live, no
restart, no force flag, and dependents need no rebuild. Nothing to propose. Saying this out loud
is what makes the rest credible — the problem is much narrower than the original RFC implied.

**Approach 2 — incompatible change: keep the version.** Archive the old contracts → upload the
new package unvetted → swap the vetted set in one topology transaction → reseed → optionally
delete the old package. Verified: zero leftovers, PID unchanged, party IDs identical, one
`mirrors 1.0.0` remaining with the new types. **No Canton change needed.**

Three corrections worth stating plainly, because two of them are corrections to *us*:

- **The force flag is not required.** We believed it was essential. It is not — an atomic swap
  never produces two same-name/same-version packages, so there is nothing to force past.
- **Archiving must come first.** Our first attempt archived after the swap and failed. Once the
  old package is unvetted, nothing from it can be exercised.
- **`TOPOLOGY_PACKAGE_ID_IN_USE` does not exist in 3.5.** The original RFC cited an error code
  that is not in the binary.

**One thing we hand them rather than ask for.** Unvetting is allowed if either no active
contracts reference the package, or another vetted package can interpret them. Our loop
satisfies the first — we archive before we unvet. But we also found that Canton allows the
unsafe case too: unvetting with 2 live contracts and no compatible version, unforced. That is on
**stable protocol version 35** with no dev flags, so it is not a sandbox concession. We do not
rely on it; we are reporting it.

**The dependency closure is the real constraint.** With A replaced incompatibly and B not
rebuilt, B can still see its contracts but cannot exercise anything —
`PACKAGE_SELECTION_FAILED`. So the loop must rebuild and reload the whole closure, and archive
every package's contracts in it.

**The one gap: reclaiming storage.** Archiving leaves history in the event log, and with
in-memory storage it grows until you restart. Canton has two mechanisms and neither is reachable
in the default sandbox — `repair.purge` we **verified working on Postgres** (2 active contracts
→ 0) but it is refused in-memory; pruning we could not get to succeed on either.

## Part 4 — questions to expect

**"Isn't this just hot reload?"**
Hot reload replaces code and the old objects are garbage. Here the old data is durable and
cryptographically tied to the code that made it. That is the whole difficulty.

**"Are you telling people to bypass safety checks?"**
No — and this got smaller than we first thought. The loop needs **no force flag at all**. It
uses ordinary Daml archival plus a normal topology transaction. We are not asking to change
production upgrade rules, and we agree the flag 3.4 removed should stay removed.

**"If it already works, why an RFC?"**
It is undocumented and unsupported, so nobody can rely on it. It has no home — ours is a shell
script. It must operate on the dependency closure to be correct, which a developer will not get
right by hand. And storage cannot be reclaimed.

**"Why not just force an incompatible version bump?"**
We tried. Canton allows it with `AllowVetIncompatibleUpgrades`, and you end up with a package
name that works for neither shape: you cannot create old-shape contracts and you cannot even
archive the existing ones. Worse than doing nothing.

**"Can't you just delete the contracts instead of archiving?"**
Yes — `repair.purge`, verified working, but only on a database-backed participant and only after
disconnecting. The default dev sandbox is in-memory, so it is refused by construction.

**"Is deleting archived contracts even legitimate?"**
Yes. Pruning is a documented, first-class Canton feature for storage management. That is why
asking why it is unusable on a dev participant is a fair question rather than a feature request.

**"Just run the sandbox on Postgres."**
Genuinely reasonable, and we tested it — `repair.purge` does work there. But it means abandoning
the default one-process dev environment, it still needs a disconnect, and `dpm sandbox` on
Postgres is **not restart-safe**: its startup bootstrap re-runs topology initialisation and dies
against already-initialised databases.

**"Does this work on a real network?"**
Untested, and deliberately out of scope. Contracts are shared across participants, so unilateral
ACS manipulation risks ACS-commitment mismatches.

**"Why 12 seconds?"**
About 1 second is Canton. The rest is three JVM startups. That is the argument for a resident
`dpm dev`, not a script.

**"What about contract keys?"**
They exist — we were wrong initially. The default compile target is LF 2.2 where keys do not
exist; `--target=2.3` compiles them and Canton accepts the package. Relevant because if B looks
contracts up **by key** instead of holding contract IDs, the reference survives a reload. Keys
fix the data linkage, not the code linkage — you still rebuild the closure.

**"Did you find anything else?"**
Two shipped-toolchain defects worth filing separately: `dpm sandbox` cannot execute a single
Daml transaction on an **Oracle JDK** (unsigned BouncyCastle vs JCE provider signing; surfaces
as an opaque `INTERNAL`), and `dpm new --template empty-skeleton` produces a project where
`dpm` exposes no subcommands at all.

## Part 5 — be honest about what is untested

Say this out loud; it is what you want colleagues to attack.

- Multi-participant behaviour — not tested, deliberately out of scope.
- In-flight submissions during the swap — not tested.
- PQS specifically — we used a polling JSON-API consumer, not PQS itself.
- Pruning — never got a successful prune, on either storage backend.
- Long sessions — about five reloads, not hundreds. Storage growth over a working day is unmeasured.
- The closure loop end-to-end — we proved a dependent **breaks** without a rebuild, but have not
  yet run the full rebuild-and-reload-the-closure sequence as one operation.

One methodological point, because it is the kind of mistake that invalidates a result: our
**first** run of the key experiment was a false positive. `propose_delta` defaults to the
Authorized topology store, which on a fresh participant is empty — so it computed a delta
against nothing, emitted serial 1, could never supersede the synchronizer's serial, changed
nothing, and **returned success.** Everything reported now targets the synchronizer store
explicitly.

## Part 6 — what you want out of this session

1. Someone to try to break the claim that Approach 2 is safe *enough* for a dev box.
2. Agreement that we should **not** propose anything for compatible changes.
3. A decision on whether to file the two toolchain defects before, with, or after the RFC.
4. Anyone who knows the Canton team: who owns `dpm`, and which of the two asks is likelier to land.

---

## Part 7 — the fix, as code

**Approach 1** needs no code. Bump the version. Done.

**Approach 2**, from `console/reload.canton`:

```scala
// 1. archive the old contracts first -- ordinary Daml Archive, as the signatories.
//    This is the only window: after the swap, nothing from the old package can be exercised.

// 2. upload the rebuilt package, switched off
val newId = sandbox.dars.upload(dar, vetAllPackages = false)

// 3. swap the allowlist in ONE topology transaction: old out, new in
sandbox.topology.vetted_packages.propose_delta(
  participant = sandbox.id,
  adds        = Seq(VettedPackage(newId, None, None)),
  removes     = Seq(oldId),
  store       = TopologyStoreId.Synchronizer(psid),   // NOT the default Authorized store
)

// 4. reseed        5. dars.remove(oldId)   (optional -- works because step 1 archived)
```

Point at `store = Synchronizer(psid)`: the default is the Authorized store, and a defaulted call
silently does nothing while returning success.

**Where it belongs:** `dpm dev`, operating on the dependency closure —

```
rebuild A, then B against the new A      (dpm already builds in dependency order)
archive B's contracts, then A's          (B first -- B references A)
upload new A and new B, both unvetted
ONE topology transaction: adds=[newA,newB]  removes=[oldA,oldB]
reseed
```

**What Canton must add:** nothing for the loop. One thing for storage — make either
`repair.purge` or pruning reachable on an in-memory development participant.

### The one-line summary for the room

> Compatible changes are already solved — bump the version. Incompatible changes work too, with
> existing APIs, and belong in `dpm dev` across the dependency closure. The only thing Canton
> has to add is a way to reclaim storage on a dev participant.
