# Development Fund Proposal: Daml Development Reload for DPM

| Field | Value |
| :---- | :---- |
| Organization | LimeChain |
| Author / Primary Contact | Georgi Radev — georgi.radev@limechain.tech |
| Status | Draft |
| Created | 2026-09-14 |
| Proposal Type | RFP-aligned |
| RFP / Roadmap Area | Developer Experience, Tooling & Education — RFP 19 (DPM Components and Extension Ecosystem); secondary RFP 18 (Integration into SDLCs) |
| Champion | Curtis Hrischuk, Digital Asset — [`hrischuk-da`](https://github.com/hrischuk-da) |
| Total Funding Request | *to be completed before submission* |
| Project Duration | ~10 weeks: 6 weeks of development, then 4 weeks of adoption support. Excludes committee review between milestones; under 6 months |
| Label | `daml-tooling` |

---

## Table of Contents

- [Abstract](#abstract)
- [Specification](#specification)
  - [1. Objective](#1-objective)
  - [2. Motivation](#2-motivation)
  - [3. Implementation Mechanics](#3-implementation-mechanics)
  - [4. Architectural Alignment](#4-architectural-alignment)
  - [5. Backward Compatibility](#5-backward-compatibility)
- [Proof of Concept Implementation](#proof-of-concept-implementation)
- [Milestones and Deliverables](#milestones-and-deliverables)
- [Acceptance Criteria](#acceptance-criteria)
- [Potential Follow-Ons](#potential-follow-ons)
- [Funding](#funding)
- [Co-Marketing](#co-marketing)
- [Rationale](#rationale)
- [About the Team](#about-the-team)
- [References](#references)

---

## Abstract

When a Daml developer makes a **breaking** change to their model — changing a field's type, dropping
a field, changing a signatory — the supported way forward is to restart the participant. That
destroys every party and every contract, and re-seeding hands back **different party IDs**, so
anything holding the old ones breaks.

We propose a DPM component that replaces the restart with an in-place reload: archive, upload
unvetted, swap the vetted set in one topology transaction, reseed. The participant keeps running and
every party ID survives.

**We have already proved the mechanism works** on stock Canton 3.5.12 / dpm-sdk 3.5.5 — no Canton
change, no protocol change, and no force flag — with committed, machine-checked logs for every
claim. What does not exist is a product: our prototype is roughly 1,500 lines of shell and Canton
console script, hardcoded to one model, with no interface any other project could use. This proposal
funds the gap between a proven technique and a supported capability.

Scope is deliberately narrow. We propose **nothing** for compatible changes — Smart Contract
Upgrades already handles those, and the tool's first action is to tell you to bump the version when
that is the right answer. We do not ask for any change to Smart Contract Upgrades or production
vetting, and the exclusions are listed in §1. Note also
that **contract identities are not preserved**: contracts are archived and recreated. What survives
is the participant process and the party IDs.

One thing worth stating up front: we set out to ask Digital Asset for a new Canton operation. After
building the proof of concept, **we withdrew that ask** — the sequence needs only APIs that already
ship.

---

## Specification

### 1. Objective

**Make the incompatible-change development reload a supported, closure-aware `dpm` capability with a
project-facing interface.**

Both capability milestones are the same difficulty class (CLI orchestration over existing
participant admin APIs), the same technology, and are delivered sequentially by the same people;
Milestone 2 is Milestone 1 generalised from one package to a dependency closure.

Deliberately **not** in this proposal, because it is a different difficulty class: reclaiming event-log
storage on a development participant. That needs a Canton-side change rather than orchestration, and
we have no evidence for it — we never got a successful prune on any backend. If the Foundation wants
it, it belongs in its own proposal.

### 2. Motivation

**The problem is not that the reload is impossible.** Our own evidence shows it working on stock
Canton. The problem is that the only *supported* path is a restart, and the alternative is an
undocumented, unsupported manual sequence with two silent failure modes.

What a developer hits today, in three steps, each taken verbatim from a committed log:

**1 — Rebuild with a breaking change at the same version, and Canton rejects it:**

```
KNOWN_PACKAGE_VERSION(8,7cd8d56a): Tried to vet two packages with the same name and
version: c17b5cb16a9d… (mirrors v1.0.0) and dba33b18bff3… (mirrors v1.0.0).
```

**2 — So you restart, and lose everything:**

```
after restart:    parties 0     contracts 0     PID 34991  (was 34023)
```

**3 — And re-seeding does not give you back what you had:**

```
-> different party id. Any app holding the old one is now broken.
```

That third line is the real cost. The restart itself takes seconds; re-establishing ledger state and
fixing every hardcoded party ID in scripts, config and test fixtures does not.

**Who this affects.** Unlike a language SDK, this has no language or framework filter: **every team
writing Daml has an inner development loop**, and DPM is the standard CLI for it — `dpm build`,
`dpm sandbox`, `dpm script`, `dpm studio`. The filter is not team type but change class: only
*breaking* changes need this, because compatible ones are already solved. Breaking changes dominate
early model design, when the shape of the model is exactly what is under discussion — which means
the population that benefits most is the one the Foundation is trying to grow, teams building their
first Canton application.

The Foundation's own 2026 developer-experience survey points the same way: **41% of respondents
named environment setup and node operations as the task that took them longest**, and local
development frameworks were rated Critical. That is evidence the inner loop is where time goes; what
it does not tell us is how often a given team makes a *breaking* model change specifically.

So we deliberately do **not** put a percentage on adoption here. We can substantiate the cost of the
event. Measured over 10 alternating trials per path, each from a fully reset ledger: the prototype
reload reaches a verified seeded state in a **median 19.9 s**, against **33.4 s** to restart and
reseed — a **40.5% reduction**, and a conservative one, since it excludes repairing everything that
still holds the old party IDs after a restart. What we cannot substantiate is how many teams hit
this or how often, and we would rather measure that in Milestone 3 than guess at it now.

### 3. Implementation Mechanics

#### 3.1 The first decision is not to reload

Not every change needs this. If the change is a *valid upgrade*, the answer is to bump the version:
Smart Contract Upgrades handles it live, and dependent packages do not even need rebuilding. The
component classifies the change using `dpm upgrade-check`, which already ships, and tells the
developer to bump the version when that is the right answer.

**We propose nothing for compatible changes.**

#### 3.2 The verified sequence

For incompatible changes, keeping the version and replacing the package:

1. **Archive** the old contracts, as their signatories. This is the only window: after the swap the
   old package is unvetted and nothing from it can be exercised, `Archive` included.
2. `dars.upload(dar, vetAllPackages = false)` — incompatible builds upload fine when unvetted.
3. **One** topology transaction:
   ```scala
   topology.vetted_packages.propose_delta(
     adds    = Seq(VettedPackage(newId, None, None)),
     removes = Seq(oldId),
     store   = TopologyStoreId.Synchronizer(psid),   // NOT the default Authorized store
   )
   ```
4. **Reseed** — parties are reused, not reallocated.
5. `dars.remove(oldId)` — optional, and only possible because step 1 archived.

**No force flag is required.** `KNOWN_PACKAGE_VERSION` is evaluated against the *resulting* vetted
set, and an atomic swap never produces two packages sharing a name and version.

#### 3.3 The two sharp edges the tool exists to absorb

These are why this belongs in a tool rather than a documentation page. Both fail *silently*.

**Store targeting.** `propose_delta` defaults to the *Authorized* store, which on a fresh participant
holds no `VettedPackages` mapping. A defaulted call computes its delta against nothing, emits serial
1, can never supersede the synchronizer's serial, **changes nothing, and returns success.** Our own
first run was a false positive for exactly this reason. The component targets the synchronizer store
and *asserts the serial advanced*.

**Ordering.** Archive before the swap, or contracts are stranded — active, uninterpretable, and no
longer archivable either. Measured on the same demo, in the two orderings:

```
Act 3 (swap first):       RELOAD orphanedContracts=2
Act 4 (archive first):    RELOAD orphanedContracts=0 … removeOld=DONE
```

The component counts and refuses rather than leaving a developer to discover this.

#### 3.4 The project-facing interface

The reload primitive is generic; the contract lifecycle around it is **inherently
project-specific**. A component cannot know which contracts matter or how to recreate application
data, so the project declares hooks, as ordinary Daml Script:

```yaml
# dev-reload.yaml
script-package: seed
hooks:
  discover: Seed:discover    # contract ids in scope, with their required signatories
  archive:  Seed:cleanup     # resolved from the BASELINE build (old shape)
  reseed:   Seed:seed        # resolved from the NEW build (new shape)
  verify:   Seed:verify      # optional postcondition, from the NEW build
```

In use, that is three commands:

```bash
dpm dev-reload init     # once, before the first edit: capture the baseline
dpm dev-reload check    # optional: validate the hooks in a throwaway sandbox
dpm dev-reload          # after each breaking change: archive, swap, reseed, verify
```

Daml Script rather than plugin code, because the project's script package already holds the
signatory authority the technique depends on and stays out of the vetting set. `discover` reports
the contracts in scope together with the signatories needed to archive them; `verify` is an optional
postcondition the project supplies, run after reseeding and before the baseline advances.

**The component never infers a migration.** If the new schema needs data the old shape cannot
supply, that is `reseed`'s job and the developer's decision.

Two constraints shape the rest. The archive hook must be built against the **old** packages and
reseed against the **new**, and the old one cannot be rebuilt once the source is edited — hence a
baseline, captured by `dpm dev-reload init` and advanced only after a reload verifies. And authority
must be established **per contract, not per declared party**, since a contract may carry an
undeclared or jointly-controlled signatory; the tool confirms it can act for every signatory it
discovers before archiving anything. The full interface is specified in the design note in the
proof-of-concept repository.

#### 3.5 Failure safety

Archival is irreversible. A naive implementation archives and then does build, upload, topology and
reseed — any of which can fail, leaving a developer with destroyed state and no reload. The ordering
is therefore a correctness property:

```
PREFLIGHT  (nothing destructive; abort freely)
  1. build the closure + script package; classify via upgrade-check
  2. upload every DAR unvetted; verify each package id is present
  3. verify environment: no peers; baseline exists; participant is idle
  4. resolve hooks; run discover; verify actAs for every required signatory
  5. read and record the synchronizer-store VettedPackages serial
COMMIT  (destructive; from here, resume rather than restart)
  6. archive          <- irreversible, and preceded by nothing that can fail
  7. propose_delta    <- assert the serial advanced from (5)
  8. reseed
  9. verify, then advance the baseline
 10. dars.remove(old) <- optional
```

Idempotency is a **documented obligation on the hook author**, not something we can prove about
arbitrary Daml Script: `archive` must converge to zero on re-run, and `reseed` must query before
creating so it does not duplicate. `dpm dev-reload check` validates both in a **throwaway sandbox** — it
cannot be checked against a live ledger, because running `reseed` twice *is* a mutation and proving
`archive` converges would destroy the state being protected.

Durable per-phase checkpoints (`archived` / `swapped` / `reseeded`) mean a failure resumes at the
right step: during archive, re-run archive; during reseed, re-run reseed.

#### 3.6 Concurrency: scoped, not claimed

Between archive and swap there is a brief window — we did not instrument its duration — in which a
running application could create a contract on the old package and strand it. We
have not verified a supported mechanism to block submissions for that window, so **we do not claim
one**. Milestone 1 is instead scoped to a participant the tool has **detected idle**, and reports
rather than prevents anything that slips through. Running an application against the ledger during a
reload is outside the supported envelope.

### 4. Architectural Alignment

- **No Canton change, no protocol change, no Ledger API change, no compiler change**, and no change
  to Smart Contract Upgrades or to production vetting. Uses only APIs shipping in Canton 3.5.12.
- We are **not** asking to reverse the 3.4 removal of
  `FORCE_FLAG_ALLOW_UNVET_PACKAGE_WITH_ACTIVE_CONTRACTS`. That removal was right and should stay. The
  flag our sequence was once thought to need is `AllowVetIncompatibleUpgrades`, which 3.4 *added* —
  and our evidence shows the sequence does not need it either.
- **DPM already owns every surrounding piece**: `dpm build` with multi-package dependency ordering,
  `dpm sandbox`, `dpm script`, `dpm studio`, `dpm upgrade-check`. Distribution follows the DPM
  component convention (`dpm add component`, `dpm publish component` to an OCI registry).
- Aligns with **RFP 19** (DPM Components and Extension Ecosystem — reusable components, conventions,
  documentation, examples, maintenance plan) and **RFP 18** (Integration into SDLCs, which names
  package vetting and environment management).
- Because the loop archives with genuine signatory authority, connected applications receive **real
  archive events** and converge by themselves — no new event type and no protocol change. We tested
  this with a polling JSON-API consumer, not with PQS; confirming PQS is a Milestone 3 deliverable,
  not a claim made here.

### 5. Backward Compatibility

*No backward compatibility impact.* The component is additive and opt-in. It does not change existing
Daml applications, Canton nodes, Ledger API semantics, package upload, or package vetting. It refuses
to run outside an isolated development participant.

---

## Proof of Concept Implementation

Public repository: **TBD — link pinned to a commit SHA before submission.** Apache-2.0.

The proof of concept changed a Daml model incompatibly on a running Canton 3.5.12 participant: same
package name, same version, no restart, party IDs preserved, zero orphaned contracts, old package
removed. Every claim below has a committed log with a provenance header (tool versions, harness
revision, clean-tree assertions) and machine-checked assertions that exit non-zero on failure.

| Claim | Evidence |
| :---- | :---- |
| Unforced `add-second` is **rejected** with `KNOWN_PACKAGE_VERSION`; forced is accepted | `C1`, `C2` |
| The atomic swap succeeds with `ForceFlags.none`, contracts archived first | `E1` |
| The same swap succeeds unforced with live contracts (stranding them) | `E2` |
| The force flag changes nothing on this path | `E3` |
| Unvetting with live contracts succeeds unforced | `E4`, `E5` |
| Determinism — three independent clean-sandbox repeats | `E6r1`–`E6r3` |
| Dependent not rebuilt → `PACKAGE_SELECTION_FAILED` | `M1` |
| Full closure swapped in **one** topology transaction, unforced | `M2` |
| PID unchanged, party IDs identical, `orphanedContracts=0`, old package removed | `STORY` |
| Reload reaches a verified seeded state in median 19.9 s vs 33.4 s to restart and reseed | `TIMING` |

**C1 and C2 are the gate**, and they are why the rest can be believed. They are a positive control
proving the harness can distinguish the two force settings at all: without them, a run that never
passed `none` and a run whose `none` was silently ignored produce identical output, and "no force
flag is needed" would be unfalsifiable by our own harness.

Method note, because it shaped the evidence: our first pass concluded a force flag *was* required. It
was not. A run's label did not match the argument actually passed to Canton — the harness selected
the flag with a string test that the op names happened to satisfy. We built the C1/C2 control, re-ran
the whole matrix against it, and corrected the claim. Every log now states the resolved force
argument as reconstructed from the value passed to Canton, not as requested by a label. The claims
survived; the evidence for them was rebuilt.

The closure result, verbatim:

```
CLOSURE_RESULT serialDelta=1 oldAVetted=false newAVetted=true oldBVetted=false newBVetted=true
PEEK label=1
```

`PEEK label=1` is the new `Int` field coming back from a rebuilt dependent fetching from a rebuilt
dependency — the whole closure live, in one transaction.

### Verified Scope and Limits

Stated flatly, because each is a question a reviewer should not have to discover:

- **Contract identities are not preserved.** Contracts are archived and recreated with new ids. The
  participant process and the party IDs survive; contract ids do not.
- **The proof of concept's archive and reseed are project-specific.** They hardcode one template and
  two party names. The general interface is Milestone 1 work, not something already built.
- **Single-participant development sandbox only.** On a multi-participant synchronizer, contracts are
  shared and unilateral ACS manipulation risks ACS-commitment mismatches. Out of scope by design.
- **Storage reclamation is untested.** `repair.purge` is verified working on Postgres and refused
  in-memory; **pruning never succeeded on any backend and we have no log for it**. Our position is
  "we did not test pruning", not "pruning does not work".
- **PQS is untested.** We substituted a polling JSON-API consumer.
- **In-flight submissions during the swap are untested**, which is why §3.6 scopes rather than claims.
- **An unexpected observation we report but do not rely on.** Unvetting a package whose active
  contracts nothing else can interpret **succeeded, unforced**, on stable protocol version 35 with no
  alpha or dev flags set (rows `E4`/`E5`). Canton 3.4's notes suggest unvetting should be safe
  *provided* a compatible package remains vetted. We archive first either way, so nothing here
  depends on it — we raise it because it may be worth Digital Asset's attention.
- **One machine.** Every result was produced on macOS with OpenJDK 21 against an in-memory sandbox.
  Linux and other projects are Milestone 3.

---

## Milestones and Deliverables

### Milestone 1: Single-Package Development Reload

**Estimated Delivery:** by week 3
**Estimated Effort:** ~3 engineer-weeks
**Focus:** A developer makes a breaking change to a single-package model and continues working
against the same participant, with the same party IDs, without restarting.

**Deliverables:**
- DPM component published to an OCI registry, installable via `dpm add component`, Apache-2.0.
- The `dev-reload.yaml` hook interface with validation, plus `dpm dev-reload init` and the baseline
  lifecycle.
- Change classification via `dpm upgrade-check`, directing compatible changes to a version bump.
- The preflight/commit sequence with checkpointed resume, serial verification, per-contract authority
  verification, and idle-participant detection.
- `dpm dev-reload check` for hook conformance in a throwaway sandbox.
- Documentation, including the hook contract and the concurrency envelope.

**Acceptance Criteria:**
- A Daml project **that is not the proof of concept**, configured only through `dev-reload.yaml`,
  completes a breaking-change reload: participant PID unchanged, every declared party ID identical,
  zero contracts left on the old package.
- The old/new boundary is exercised: the archive hook consumes old-schema contracts while the reseed
  hook creates the new schema. Running with no baseline refuses and names `init`.
- A committee member or delegate performs the reload following only the published documentation, with
  no assistance from us, on a project of their choosing.
- **Measured iteration time**, protocol stated: median wall-clock from saving a breaking change to an
  **equivalent logical seeded state** — the model's parties exist and the seed data is verified —
  over ≥10 alternating trials per path against the restart-and-reseed baseline, same project and
  machine, first trial of each path discarded, each trial from a reset ledger. The baseline reaches
  that state with **newly allocated party IDs**, and the comparison **excludes** the work of repairing
  scripts and config that still hold the old IDs, so the figure is a conservative floor. Target
  **≥40% reduction** — the shell prototype already achieves 40.5% under this protocol, and the
  product should improve on it by holding one admin connection instead of launching five processes.
- **Party IDs are preserved across the reload** — stated separately from the timing, since the
  baseline cannot satisfy it by construction. A different
  threshold may be agreed with the committee at grant time.
- **Injected failures** at five boundaries behave correctly: upload failure, hook-resolution failure
  and a concurrently-changed topology serial each abort in preflight with no archival and no topology
  change; a failure mid-archive resumes and converges; a failure mid-reseed resumes without
  duplicating. The baseline is unchanged unless the reload completed and verified.
- Refusals exit non-zero, name the reason, and make **no topology or ACS change** — asserted, not
  described — for: participant has peers; no baseline; a mixed-authority discovered set; and a
  participant whose ledger offset is advancing.

### Milestone 2: Dependency-Closure Reload

**Estimated Delivery:** by week 6
**Estimated Effort:** ~2 engineer-weeks
**Focus:** Real Daml projects are multi-package. Changing one package silently breaks its dependents,
and today the only signal is an error that names nothing.

**Deliverables:**
- Closure computation from `multi-package.yaml` and `data-dependencies`; rebuild in dependency order;
  **archive in reverse dependency order** (dependents before dependencies).
- All adds and removes in **one** `propose_delta` across the closure.
- Diagnosis of the stale-dependent failure, replacing
  `PACKAGE_SELECTION_FAILED: No synchronizers satisfy the topology requirements` — which teaches
  nothing — with the package that must be rebuilt and why.
- Documentation with a worked multi-package example.

**Acceptance Criteria:**
- A multi-package project reloads a breaking change across its full closure in one operation, with
  dependents working immediately afterwards — demonstrated on a project that is not the proof of
  concept, and reproducible by a committee member or delegate.
- Given a closure with dependents omitted, the tool names **every** omitted dependent and the
  dependency that forced it, and exits non-zero **before** any topology or ACS change — verified
  against a fixture with at least two omitted dependents, so "every" is decidable.
- Closure iteration-time measurement against the multi-package restart baseline, same protocol and
  target as Milestone 1.
- A build failure in one package aborts with no archival anywhere in the closure.

### Milestone 3: Adoption, Documentation and Ecosystem Validation

**Estimated Delivery:** weeks 7–10; acceptance at week 10, when the adoption window closes
**Estimated Effort:** ~3 engineer-weeks (delivery plus support across the adoption window)
**Focus:** Establish that the capability is *supported* — usable by developers with no contact with
us. "Supported" is not a property of code; no artifact can demonstrate it.

Development finishes with Milestone 2. Milestone 3 is a **four-week adoption window**: the release
and documentation land at the start of it, and the remaining effort is support while independent
teams exercise the tool on their own projects. Acceptance falls at the end of the window, because
the criteria below require those teams to have used it and reported.

Participating teams will be recruited through the Daml Language & Developer Tooling SIG channel, the
Canton Network forum, and direct approach to teams already publishing multi-package Daml projects.
We have not pre-committed any organisation, and would rather say so than imply arrangements that do
not exist.

**Deliverables:**
- Public release and OCI component publication.
- **A maintenance commitment**, not merely a plan: LimeChain will maintain the component for **6
  months following final delivery**, including restoring compatibility with new Daml SDK releases
  within **60 days** of each release, and triaging issues reported against the documented workflow.
- Quickstart — "keep your ledger alive through a breaking model change" — with an example repository,
  plus a recorded walkthrough.
- Submission of the workflow for inclusion in Canton/Daml developer documentation, and a presentation
  to the Daml Language & Developer Tooling SIG.
- Hands-on sessions with independent Canton teams; triage and fixes for adoption blockers.
- A **PQS pass-through check with a real consumer**, delivered as a documented result either way,
  since the proof of concept used a substitute.
- An adoption report with measured before/after iteration times from projects that are not ours.

**Acceptance Criteria:**
- At least **three independent organisations** use the reload on their own project and report in
  writing whether it changed their development loop and how.
- At least **one** of those is a multi-package project.
- The adoption report contains **measured** before/after iteration times from at least three projects
  that are not ours, replacing the estimates in this proposal.
- A developer new to the tool completes the quickstart and performs a reload **with no LimeChain
  assistance**.
- The workflow is accepted into, or formally submitted for inclusion in, Canton/Daml developer
  documentation.
- Any issue blocking the documented happy path is fixed or documented with a workaround.

---

## Acceptance Criteria

The Tech & Ops Committee will evaluate completion based on:

- Deliverables completed as specified for each milestone.
- All software released open source under Apache-2.0 before any milestone payment.
- The component installs and runs in a clean environment via `dpm add component`.
- The workflow is correct on the then-current stable Daml SDK, not only the 3.5.5 the proof of
  concept used.
- Documentation sufficient for an independent Canton developer, including the stated limits and the
  concurrency envelope.
- A committee member or delegate can perform the reference flow end to end.

Ecosystem value will be measured by the Milestone 3 adoption report, the measured iteration-time
improvement on projects that are not ours, and inclusion of the workflow in Canton/Daml developer
documentation.

---

## Potential Follow-Ons

Listed for context; **not part of this funding request**.

- **Storage reclamation on a development participant** — repair-style contract removal or usable
  pruning on an in-memory participant. Different difficulty class, needs a Canton-side change, and we
  have no evidence for it today.
- **An enforced commit-window quiesce**, if a supported mechanism exists — which would let the tool
  close the concurrency window in §3.6 outright rather than detecting and refusing.
- **Daml Studio integration** — reload on save. Different codebase, different direction.
- **A resident daemon.** The measured prototype reload is ~19.9 s, and it launches five separate JVM
  processes to get there (build, archive script, console, reseed script, verify). Holding one admin
  connection instead would remove most of that repeated startup cost; we have not instrumented the
  per-component split, so we state the opportunity rather than a projected figure.
- **Multi-participant development topologies.**

---

## Funding

**Total Funding Request:** *to be completed before submission.*

The work is scoped at **~8 engineer-weeks across the three milestones**, delivered by **one
engineer**, plus **~2 engineer-weeks** for the six-month maintenance commitment — so the effort
basis is stated even while the figure is pending.

### Payment Breakdown by Milestone

- Milestone 1, Single-Package Development Reload: **30%** upon committee acceptance
- Milestone 2, Dependency-Closure Reload: **30%** upon committee acceptance
- Milestone 3, Adoption, Documentation and Ecosystem Validation: **40%** upon committee acceptance
  and the adoption criteria

The largest share sits on Milestone 3 because that is where ecosystem value is demonstrated rather
than asserted, and because it carries both the adoption window and the maintenance commitment. The
capability milestones are weighted to reflect that their engineering — the hook interface, baseline
lifecycle and failure-safety work — does not exist yet, however well-proven the underlying sequence
is.

### Volatility Stipulation

The project duration is under 6 months. Should the timeline extend beyond 6 months due to
Committee-requested scope changes, any remaining milestones will be renegotiated to account for
USD/CC price volatility.

---

## Co-Marketing

Upon release, LimeChain will collaborate with the Foundation on:

- A technical blog post: *"Changing a Daml model without restarting Canton — and why it needs no
  force flag."*
- A short recorded walkthrough of the reload.
- A presentation to the Daml Language & Developer Tooling SIG.
- Submission of the workflow for inclusion in Canton/Daml developer documentation.

---

## Rationale

**We are extending DPM, not replacing anything.** DPM already owns build with multi-package
dependency ordering, the sandbox, script execution, Studio launch and upgrade checking. The reload is
orchestration over those plus two admin calls, distributed through the DPM component convention the
Foundation is actively soliciting under RFP 19.

**We removed our own protocol ask.** Our original internal RFC proposed a new Canton operation,
`ReplacePackageRequest`. Building the proof of concept showed it unnecessary. We would rather report
that than ask for surface we do not need.

**Why `dars.vetting.enable` cannot carry this — two reasons.** It has no force parameter (verified
against the shipped Canton 3.5.12 jar), so it fails with `KNOWN_PACKAGE_VERSION`. More
fundamentally, it cannot express an atomic add-and-remove in a single transaction against a chosen
store — and that atomicity is precisely what makes the operation legal *without* a force flag. Note
what this implies: the fix is **not** "add a force parameter to `dars.vetting.enable`". Forcing is
the wrong answer, and our E1/E3 evidence shows the flag is inert on this path.

**Why not just publish a runbook.** Two traps make unassisted execution unreliable, and both fail
silently: the default Authorized store no-ops while returning success, and archiving after the swap
strands contracts permanently. Documentation cannot verify a topology serial, cannot check per-contract
authority before archiving, and cannot resume a half-finished reload.

**Why not version bumping.** Because it already works for compatible changes, and we propose nothing
there. The boundary is sharp: an incompatible change at a higher version is rejected with
`NOT_VALID_UPGRADE_PACKAGE`, and forcing across it produces a package that works for neither shape —
you can neither create old-shaped contracts nor archive the existing ones. That is a data-shape
impossibility, not a permissions check. **We are not asking for a way to force it.**

**Why not storage reclamation here.** Different difficulty class, and no evidence. Including it would
violate the template's own warning about deliverables of greatly differing difficulty.

---

## About the Team

LimeChain has built and shipped blockchain infrastructure and developer tooling since 2017.

*Track record: **TBD before submission** — named prior work, ecosystems, and engagement durations to
be listed here.*

How we work is visible in this proposal's evidence base. We set out to prove a result and then tried
to disprove it: we found a mislabelling defect in our own test harness, built a control that would
fail if the harness could not distinguish the two configurations it was comparing, re-ran the entire
matrix against that control, and published every log — including the correction. We would rather
hand a committee an audited result than a confident one.

Building the proof of concept also surfaced six defects in the shipped toolchain — among them an
Oracle JDK / BouncyCastle interaction that makes every Daml transaction fail with an opaque
`INTERNAL`, `dpm new --template empty-skeleton` omitting `sdk-version`, and a Postgres sandbox that
is not restart-safe. We are filing these with Digital Asset independently of this proposal.

---

## References

- This proof of concept — repository **TBD**, `evidence/INDEX.md` for the claim-to-log map
- Canton 3.4 release notes (Splice 0.5.0) — cited for the **force-flag history**, not the tested
  version: 3.4 is where `FORCE_FLAG_ALLOW_UNVET_PACKAGE_WITH_ACTIVE_CONTRACTS` was removed and
  `AllowVetIncompatibleUpgrades` added, and where the unvetting guidance in §3.6 comes from. All
  testing in this proposal was done against **Canton 3.5.12 / dpm-sdk 3.5.5**.
  https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0
- Canton package management and vetting —
  https://docs.daml.com/canton/usermanual/packagemanagement.html#understanding-package-vetting
- Digital Asset developer documentation — https://docs.digitalasset.com/
