# Development Model Reload

**Let developers change a Daml model on a running participant — no restart, no lost parties**

> Revised 2026-08-24. Supersedes the original draft, which was written against the Canton 3.4
> release notes. Every claim here was tested against **Canton 3.5.12 / dpm-sdk 3.5.5**; the
> harness, commands and verbatim error strings are in **RESULTS.md** and **README.md**.

---

## 1. Summary

We set out to ask for a new Canton operation. After building it, **we are not asking for one.**

There are two ways to change a model on a live participant, and which you need depends only on
whether your change is a valid upgrade:

| Your change | Approach | Status today |
|---|---|---|
| **compatible** — add an optional field, add a choice | **bump the version** (`1.0.0` → `1.0.1`) | Fully supported. Works live. Dependent packages need no rebuild. **Nothing to do.** |
| **incompatible** — change a type, drop a field, change a signatory | **keep the version**: archive → replace → reseed | Works with existing APIs. Undocumented, unsupported, and has no home. |

So this RFC asks for three small things:

1. **Bless the second sequence** as a supported development workflow, and give it a home —
   `dpm dev`, operating on the whole dependency closure.
2. **Make storage reclamation available on a development participant.** Both mechanisms
   (`repair.purge`, pruning) exist and neither works on the default in-memory sandbox.
3. **Confirm one behaviour** we observed and did not expect (§5) — we do not depend on it, but
   it does not look development-scoped.

---

## 2. Approach 1 — compatible changes are already solved

Uploading a higher version while the current one is live and holding contracts is accepted, no
restart, no force flag. Both versions end up vetted simultaneously.

**And dependent packages do not need rebuilding.** We verified this with a two-package project
where B holds a cross-package `ContractId` into A and `fetch`es it. After upgrading A to
1.0.1, B — never rebuilt — kept working, and a script compiled against A 1.0.0 created new
contracts at 1.0.1 by itself. Canton resolves templates by package *name* and picks the newest
compatible version.

**We are not proposing anything here.** Smart Contract Upgrades already does this correctly,
and any developer whose change is compatible should simply bump the version. Saying so is part
of the proposal: the dev-loop problem is narrower than the original RFC implied.

The boundary is sharp: an incompatible change at a higher version is rejected with
`NOT_VALID_UPGRADE_PACKAGE`, and that is correct behaviour we do not want changed.

### Forcing across that boundary does not work

`ForceFlag.AllowVetIncompatibleUpgrades` *will* vet an incompatible bumped version. The result
is a package name that works for neither shape: you cannot create contracts of the old shape
(`COMMAND_PREPROCESSING_FAILED: mismatching type: Int64 and value: Text(…)`) and you cannot
even archive the existing ones (`INTERPRETATION_UPGRADE_ERROR_TRANSLATION_FAILED`). You are
left with data you can neither use nor remove.

This is why no flag or event can bridge an incompatible change: existing contracts physically
store the old shape, and a package expecting the new one cannot read those bytes. It is a
data-shape impossibility, not a permissions check. **We are not asking for a way to force it.**

---

## 3. Approach 2 — the loop for incompatible changes

Verified end to end, single package:

```scala
// 1. archive the old contracts, as their signatories, while the old package is
//    still the only vetted one. This is the ONLY window in which it is possible.
//    (In a development environment the developer allocated every party, so they
//     hold the authority to do this. That is what makes it inherently dev-only.)

// 2. upload the rebuilt package, unvetted
val newId = sandbox.dars.upload(dar, vetAllPackages = false)

// 3. swap the vetted set in ONE topology transaction
sandbox.topology.vetted_packages.propose_delta(
  participant = sandbox.id,
  adds        = Seq(VettedPackage(newId, None, None)),
  removes     = Seq(oldId),
  store       = TopologyStoreId.Synchronizer(psid),   // NOT the default Authorized store
)

// 4. reseed        5. dars.remove(oldId)  (optional)
```

Outcome: `orphanedContracts=0`, participant PID unchanged, party IDs identical, and exactly one
`mirrors 1.0.0` remaining — carrying the new types.

**No force flag is required.** `KNOWN_PACKAGE_VERSION` evaluates the *resulting* vetted set, and
an atomic swap never produces two same-name/same-version packages. (We originally believed the
force flag was essential. It is not; that was our error.)

### Order matters, and archiving must come first

Archiving after the swap fails both ways: once the old package is unvetted nothing from it can
be exercised, and re-vetting both to work around that hits upgrade name-resolution
(`TypeMismatch(TBuiltin(BTText),Int64(42))`). The window to archive is before the swap.

### It must operate on the dependency closure

A package's compiled code embeds its dependencies' package IDs, so changing A forces a rebuild
of B, which changes B's ID, and so on. We verified the failure: with A replaced incompatibly
and B not rebuilt, B can still see its contracts but cannot exercise anything —
`PACKAGE_SELECTION_FAILED: No synchronizers satisfy the topology requirements`.

So the workflow is closure-wide:

```
rebuild A, then B against the new A          (dpm already builds in dependency order)
archive B's contracts, then A's              (B first -- B references A)
upload new A and new B, both unvetted
ONE topology transaction: adds=[newA,newB]  removes=[oldA,oldB]
reseed
```

### Where it should live

`dpm dev`. This is orchestration, not protocol — and DPM already owns every surrounding piece:
`dpm build` with multi-package dependency ordering, `dpm sandbox`, `dpm script`, and
`dpm studio`'s existing reload-on-change. Our prototype is 215 lines of shell and console
script, which is precisely the problem: nobody can depend on that.

A timing note that argues for a resident tool rather than a script: one reload takes ~12s in
our harness and almost none of it is Canton. It is three JVM launches; a no-op console session
alone costs ~3s, so the upload and topology transaction together are about 1s. A resident
`dpm dev` holding one admin connection would not pay that per save.

---

## 4. The gap: reclaiming storage

Archiving removes contracts from the active set — nothing queries them, they block nothing, and
`dars.remove` succeeds afterwards. What accumulates is **history** in the event log, and with
`storage = memory` it grows monotonically until you restart. Every save adds to it, so this is
a hard limit on how long a development session can run, not a tidiness issue.

Canton already has both mechanisms. Neither is reachable where developers work:

| Mechanism | What it does | In-memory sandbox | DB-backed |
|---|---|---|---|
| `repair.purge` | deletes active contracts outright, no archive events | **refused** — *"is in memory which is not supported by repair. Use db persistence."* | **verified working**: 2 active contracts → 0 |
| pruning | deletes archived contracts and history | refused | **not verified** — `UNSAFE_TO_PRUNE … max deduplication duration of 168h`, then *"no suitable offset"*; `find_safe_offset` returns `None` |

`repair.purge` additionally requires disconnecting from the synchronizer first.

**This is the one thing we are asking for.** Not a new capability — an existing one, made
reachable on a single-process development participant. Either would do:

- allow repair-style contract removal on an in-memory participant (with it, Approach 2 would
  not need to archive at all), or
- make pruning usable there, so archived history can be reclaimed.

Note also that the DB-backed route is not a workaround: `dpm sandbox` on Postgres is not
restart-safe, because its startup bootstrap re-runs topology initialisation and fails against
already-initialised databases.

---

## 5. An observation for you — not a dependency

Unvetting a package is permitted if **either** of two conditions holds:

- **(a)** no active contracts reference it, **or**
- **(b)** some other vetted package can still interpret those contracts

**Our loop satisfies (a).** We archive before we unvet, so the old package has zero active
contracts at that moment. The compatibility question in (b) never arises, and nothing in this
proposal depends on it.

But while testing we also tried the unsafe path — unvetting a package that still had **2 live
contracts**, with no compatible version anywhere, so neither (a) nor (b) held. It **succeeded,
unforced**:

```
PRE  v1Vetted=true  contracts=2
RESULT unvet-noforce => SUCCEEDED
POST v1Vetted=false contracts=2
```

Those contracts are now interpretable by nothing. Canton 3.4's notes suggest unvetting should
require condition (b) when (a) fails, so we expected a rejection or at least a force flag.

**And this is not a sandbox relaxation.** The participant was running **stable protocol
version 35** (`stable = List(34, 35)`, `alpha = List(dev)`, `latest = 35`) with no
`alpha-version-support`, `beta-version-support` or dev flags set — Canton ships a separate
`alpha.conf` for relaxed behaviour and we were not using it. So a production participant should
behave the same way.

> **Is that intended, or a gap you would want to close?**

Closing it would not affect this proposal — we archive first either way. We are raising it
because it looked like an invariant you may intend to hold, and it is not scoped to development.

## 6. What we are not asking for

**A new package-replacement operation.** The original RFC proposed `ReplacePackageRequest`.
Not needed — the sequence in §3 uses existing APIs.

**`development: true` in `daml.yaml`.** Dropped. It would require the flag to survive
compilation in trustworthy DAR metadata, dragging in the compiler and package format. Approach
2 is inherently development-only for a better reason: it depends on the caller holding every
party's signatory authority, which is only true when you allocated them all yourself.

**Mass administrative archival.** The original proposed archiving every contract "using normal
archive events". An administrator cannot produce those — the implicit `Archive` choice is
controlled by the signatories. In a development environment the developer *is* every signatory,
so ordinary Daml archival is sufficient and honest.

**A new event on the update stream.** Because Approach 2 archives contracts with genuine
signatory authority, connected applications and PQS receive **real archive events** and converge
by themselves. No protocol change is needed. (If repair-style removal became available per §4,
the question of what consumers observe would return — but it is not needed today.)

**Any change to smart contract upgrades, or to production vetting.** Upgrade rules stay exactly
as they are. Removing `FORCE_FLAG_ALLOW_UNVET_PACKAGE_WITH_ACTIVE_CONTRACTS` in 3.4 was right
and should stay.

**Stable package IDs.** The ID is a hash and must remain one.

**Multi-participant support.** Everything here was tested on a single-participant sandbox. On a
real synchronizer contracts are shared, and unilateral ACS manipulation risks ACS-commitment
mismatches. We are not proposing this outside an isolated development participant.

---

## 7. Open questions

1. §5 — is it intended that a participant on a stable protocol version will unvet a package
   whose active contracts nothing else can interpret, unforced?
2. Should the drop-contracts primitive (§4) take a package ID and derive the contract set, or
   should the caller supply contract IDs? We would prefer the former; `repair.purge` requires
   the latter, which races with concurrent activity.
3. Should it require a synchronizer disconnect? `repair.purge` does; we would rather it did not,
   so connected applications stay undisturbed.
4. What happens to submissions in flight during the swap? Untested. We expect a quiesce stage
   is needed and would like guidance on the mechanism.
5. Should `dpm dev` archive and reseed automatically, or print the counts and wait?
6. Is there a supported way to reclaim event-log storage on a development participant that we
   have missed?

---

## 8. What we are asking

1. **Bless the §3 sequence** as a supported development workflow, and confirm `dpm dev` as its
   home, operating on the dependency closure.
2. **Make storage reclamation reachable on a development participant** — repair-style contract
   removal or usable pruning, per §4.
3. **Confirm §5** — an observation we are handing you, not a dependency.

Smaller, if you want them: `propose_delta` silently succeeding when it targets a store whose
serial cannot win is a sharp edge worth fixing, and `dars.vetting.enable` cannot express a
forced vet at all (no force parameter) — which is why the original RFC concluded this was
impossible.

---

## Appendix — defects found while building the POC

Unrelated to the proposal, but found in the shipped toolchain.

1. **`dpm sandbox` cannot execute any Daml transaction on an Oracle JDK.** The fat jar bundles
   BouncyCastle unshaded and unsigned; Oracle JDKs enforce JCE provider signing, OpenJDK builds
   do not. `SecurityException: JCE cannot authenticate the provider BC` →
   `JarException: … is not signed`, surfacing to the client as an opaque `INTERNAL`. Upload,
   party allocation and topology all work, so the environment looks healthy until the first
   submit. Oracle 17.0.7 and 18.0.2 fail; OpenJDK 21.0.12.1 works.
2. **`dpm new --template empty-skeleton` omits `sdk-version`**, after which `dpm` exposes no
   subcommands — `dpm build` reports `unknown command "build" for "dpm"`.
3. **`dpm sandbox` on Postgres is not restart-safe** (§4).
4. **Postgres on macOS cannot host Canton** — Canton sets the Linux-only
   `client_connection_check_interval`, which Homebrew Postgres 14 rejects.
5. **The sequencer needs two separate databases** (node store and reference-driver store), or
   Flyway migrations collide.
6. **Contract keys are available but off by default** — the default target is LF 2.2; keys need
   `--target=2.3`, which damlc supports and Canton accepts.

## References

- This POC — `README.md`, `RESULTS.md`, `logs/ladder.log`
- Canton 3.5.12 binary — `ForceFlag` inventory; `KNOWN_PACKAGE_VERSION`; `ParticipantRepairService.PurgeContracts`; `UpdateVettedPackages`
- Canton 3.4 release notes (Splice 0.5.0) — https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0
- Manage Daml packages and archives — https://docs.digitalasset.com/operate/3.3/howtos/operate/packages/packages.html
- DPM docs — https://docs.digitalasset.com/build/3.4/dpm/dpm.html
