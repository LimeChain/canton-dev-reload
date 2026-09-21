# Development Fund Proposal: FRED, Daml Development Reload for DPM

> Second edition, revised to Champion feedback, and naming the component FRED. The first edition is
> retained as
> `2026-09-LimeChain-daml-dev-reload.md`. The copy submitted to
> `canton-foundation/canton-dev-fund` is authoritative.

| Field | Value |
| :---- | :---- |
| Organization | LimeChain |
| Author / Primary Contact | Georgi Radev, georgi.radev@limechain.tech |
| Status | Draft |
| Created | 2026-09-14 |
| Proposal Type | RFP-aligned |
| RFP / Roadmap Area | Developer Experience, Tooling & Education. RFP 19, secondary RFP 18 |
| Champion | Curtis Hrischuk, Digital Asset, [`hrischuk-da`](https://github.com/hrischuk-da) |
| Total Funding Request | *to be completed before submission* |
| Project Duration | ~10 weeks: 6 weeks building the capability, then a 4-week release and adoption window. Under 6 months |
| Label | `daml-tooling` |

---

## Abstract

A Daml developer who makes a breaking change to their model, such as changing a field's type or a
signatory, must restart the participant. The restart destroys every party and every contract, and
re-seeding returns different party IDs, so scripts, configuration and applications holding the old
ones break. We propose FRED, a DPM component that replaces the restart with an in-place reload: archive
the affected contracts, upload the rebuilt DAR unvetted, swap the vetted package set in a single
topology transaction, then reseed. The participant keeps running and every party ID survives.
Contracts are archived and recreated, so contract IDs change. We have already proved this mechanism
on stock Canton 3.5.12, with no Canton change and no force flag, and published a machine-checked log
for every claim. This grant funds the gap between a proven sequence and a supported capability that
any Daml project can use.

---

## Specification

### 1. Objective

By the end of this grant a Daml developer will change a model incompatibly and carry on working
against the same running participant, with the same party IDs, using one command. The capability
ships as FRED, a DPM component installable with `dpm add component`, configured by a small file in the
project that names four Daml Script hooks, and documented well enough for a developer with no
contact with us to use it on their own project.

Why now. DPM is new and the Foundation is soliciting components for it under RFP 19, so the extension
point exists and its conventions are being set now. The sequence is already proven and needs nothing
from Canton, making this orchestration rather than protocol work.

### 2. Implementation Mechanics

The reload is four steps against the running participant. Archive the contracts of the changed
packages, using the signatory authority the developer already holds because they allocated the
parties. Upload the rebuilt DAR unvetted. Swap the vetted package set, removing the old package IDs
and adding the new ones, in a single topology transaction against the synchronizer store. Reseed the
working state. No force flag is needed, because an atomic swap never leaves two packages sharing a
name and version.

Two details carry the design, and both fail silently when got wrong, which is why this belongs in a
tool rather than a documentation page. The topology call defaults to a store where it changes nothing
and still returns success, so FRED targets the synchronizer store and asserts the serial
advanced. And archiving must precede the swap, because afterwards the old package is unvetted and its
contracts can no longer be archived at all.

The lifecycle around the reload is project-specific, so the project declares four hooks as ordinary
Daml Script: discover, archive, reseed and verify. Every irreversible step is preceded only by steps
that can fail safely. The supported target is the development sandbox. The appendix links the full
interface specification.

### 3. Architectural Alignment

No Canton change, no protocol change, no Ledger API change and no compiler change. FRED uses
only APIs shipping in Canton 3.5.12 and alters nothing about Smart Contract Upgrades or production
vetting.

DPM already owns every surrounding piece: build with multi-package dependency ordering, the sandbox,
script execution, Studio launch and upgrade checking. Distribution follows the DPM component
convention. The work aligns with RFP 19 on DPM components and the extension ecosystem, and with
RFP 18 on integration into SDLCs, which names package vetting and environment management.

### 4. Backward Compatibility

No backward compatibility impact. FRED is additive and opt-in. It does not change existing
Daml applications, Canton nodes, Ledger API semantics, package upload or package vetting. It refuses
to run outside a development participant it has detected to be idle.

---

## Milestones and Deliverables

### Milestone 1: Single-Package Reload in the Sandbox

**Estimated Delivery:** week 3
**Estimated Effort:** ~3 engineer-weeks

A developer makes a breaking change to a single-package model and carries on against the same sandbox
participant, with the same party IDs.

**Deliverables:** FRED, published to an OCI registry under Apache-2.0 and installable
with `dpm add component`; the hook interface and baseline lifecycle; change classification that sends
compatible changes to a version bump instead; the preflight and commit sequence with checkpointed
resume, serial and authority verification, and idle detection; a conformance check for hooks; and
documentation.

**Acceptance Criteria:** a project that is not the proof of concept completes a breaking-change
reload, configured only through its hook file, with the participant process unchanged, every declared
party ID identical, and no contracts left on the old package. A committee member or delegate performs
that reload from the published documentation alone. Median iteration time is at least 40% below the
restart-and-reseed baseline, over at least ten alternating trials per path from a reset ledger.
Injected failures at five boundaries either abort with nothing destroyed or resume and converge.

### Milestone 2: Dependency-Closure Reload

**Estimated Delivery:** week 6
**Estimated Effort:** ~3 engineer-weeks

Real Daml projects are multi-package. Changing one package breaks its dependents, and today the only
signal is an error that names nothing.

**Deliverables:** closure computation from the project's multi-package configuration; rebuild in
dependency order and archive in reverse dependency order; every add and remove in one topology
transaction; a diagnosis naming the package that must be rebuilt, replacing the current
`PACKAGE_SELECTION_FAILED`; and a worked example.

**Acceptance Criteria:** a multi-package project that is not the proof of concept reloads across its
full closure in one operation, with dependents working immediately afterwards, and a committee member
reproduces it. Given a closure with dependents omitted, the tool names every one of them and exits
before any change. Closure iteration time meets the Milestone 1 target.

### Milestone 3: LocalNet Validation, Documentation and Adoption

**Estimated Delivery:** weeks 7 to 10
**Estimated Effort:** ~4 engineer-weeks

Development finishes with Milestone 2. This milestone is a four-week window in which the release and
documentation land at the start and independent teams use the tool on their own projects.

**Deliverables:** public release and OCI component publication; a quickstart with an example
repository and a recorded walkthrough; submission of the workflow for inclusion in Canton and Daml
developer documentation, and a presentation to the Daml Language and Developer Tooling SIG; hands-on
sessions with independent teams recruited through that SIG and the Canton Network forum; a PQS
pass-through check with a real consumer; a LocalNet validation report covering a network with multiple
validators, published whatever it finds; and six months of maintenance, restoring compatibility with
each new Daml SDK release within 60 days.

**Acceptance Criteria:** at least three independent organisations use the reload on their own project
and report in writing whether it changed their development loop and how, with at least one
multi-package project among them. The adoption report carries measured before-and-after iteration
times from those projects. A developer new to the tool completes the quickstart and performs a reload
with no LimeChain assistance. The LocalNet report is published.

---

## Acceptance Criteria

The Tech & Ops Committee will evaluate completion on ecosystem outcomes rather than on artifacts
alone.

Value delivered: independent teams report a measurably shorter code-test-debug cycle on their own
projects, and the Milestone 3 adoption report carries those measurements. The workflow is accepted
into, or formally submitted for inclusion in, Canton and Daml developer documentation.

Usable without us: a developer with no contact with LimeChain installs FRED in a clean
environment and completes a reload from the published documentation, on the then-current stable Daml
SDK.

Open by default: all software is released under Apache-2.0 before any milestone payment, and the
LocalNet result is published whether or not it succeeds.

---

## Funding

**Total Funding Request:** *to be completed before submission.*

The work is 10 engineer-weeks delivered by one engineer over about 10 calendar weeks: 3 for
Milestone 1, 3 for Milestone 2 and 4 for Milestone 3. A further 2 engineer-weeks covers the six-month
maintenance commitment after final delivery. The effort basis is stated so the figure can be checked
against it.

### Payment Breakdown by Milestone

- Milestone 1, Single-Package Reload in the Sandbox: **30%** upon committee acceptance
- Milestone 2, Dependency-Closure Reload: **30%** upon committee acceptance
- Milestone 3, LocalNet Validation, Documentation and Adoption: **40%** upon committee acceptance and
  the adoption criteria

The largest share sits on Milestone 3 because that is where ecosystem value is demonstrated rather
than asserted, and because it carries both the adoption window and the maintenance commitment.

### Volatility Stipulation

The project duration is under 6 months. Should the timeline extend beyond 6 months due to
Committee-requested scope changes, any remaining milestones will be renegotiated to account for
USD/CC price volatility.

---

## Co-Marketing

Upon release, LimeChain will collaborate with the Foundation on a technical blog post, a short
recorded walkthrough of the reload, a presentation to the Daml Language and Developer Tooling SIG,
and submission of the workflow for inclusion in Canton and Daml developer documentation.

---

## Motivation

The code-test-debug cycle is where Daml developers spend their time, and a breaking model change
currently resets it. Restarting the participant destroys every party and every contract. Re-seeding
returns different party IDs, so the real cost is not the restart, which takes seconds, but repairing
every script, configuration file and test fixture that held the old IDs.

The Foundation's 2026 developer-experience survey points the same way. 41% of respondents named
environment setup and node operations as the task that took them longest, and local development
frameworks were rated Critical.

This has no language or framework filter. Every team writing Daml has an inner development loop, and
DPM is the standard CLI for it. The filter is change class, not team type: Smart Contract Upgrades
already solves compatible changes, while breaking changes dominate early model design, which is the
population the Foundation is trying to grow.

Existing test tooling does not reach this. `dpm test` and the Daml Studio script runner run against
the compiler's own ephemeral in-memory ledger, with no participant and no topology, so they cannot
tell you whether a new model can replace the old one on a participant that is already running.

Measured on the prototype, a reload reaches a verified seeded state in a median 18.5 seconds against
30.6 seconds to restart and reseed. The gap widens in longer-lived environments and in CI, where the
destroyed state took longer to build.

---

## Rationale

We are extending DPM, not replacing anything. The reload is orchestration over capabilities DPM
already owns, plus two admin calls, distributed through the component convention the Foundation is
soliciting under RFP 19.

We removed our own protocol ask. Our internal RFC proposed a new Canton operation. Building the proof
of concept showed it unnecessary, and we would rather report that than request surface we do not need.

A runbook cannot carry this. Documentation cannot verify a topology serial, check per-contract
authority before archiving, or resume a half-finished reload.

---

## About the Team

LimeChain has built and shipped blockchain infrastructure and developer tooling since 2017.

*Track record: **TBD before submission**. Named prior work, ecosystems and engagement durations to be
listed here.*

How we work is visible in the evidence base. We set out to prove a result and then tried to disprove
it: we found a mislabelling defect in our own test harness, built a control that would fail if the
harness could not tell the two configurations apart, re-ran the entire matrix against it, and
published every log including the correction.

The proof of concept also surfaced six defects in the shipped toolchain, which we are filing with
Digital Asset independently of this proposal.

---

## Appendix: Mechanism and Evidence

Public repository: <https://github.com/LimeChain/canton-dev-reload> (Apache-2.0), pinned for review at
[`harness-v12`](https://github.com/LimeChain/canton-dev-reload/tree/harness-v12). Tags there are
provenance anchors and never move, so the link is stable; `main` is not and should not be cited.

That repository is the evidence base, not the product. Fourteen committed runs back the claims here:
the unforced swap succeeds with contracts archived first; a control pair proves the harness can tell
the two force settings apart at all, which is what makes the headline falsifiable; a dependent left
unrebuilt fails; a full closure swaps in one topology transaction; party IDs survive and ordering
decides whether contracts are stranded. Every log carries a provenance header and machine-checked
assertions that exit non-zero on failure.
[`evidence/INDEX.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v12/evidence/INDEX.md)
maps each claim to its log and states what the runs do not establish.
[`docs/design-note.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v12/docs/design-note.md)
specifies the hook interface, the baseline lifecycle, the commit ordering and the concurrency
envelope.

One method note, because it shaped the evidence. Our first pass concluded that a force flag was
required. It was not: a run's label did not match the argument actually passed to Canton. We built the
control pair, re-ran the whole matrix against it, and corrected the claim. The evidence was produced
on one machine, macOS with OpenJDK 21, against an in-memory sandbox.

References: [Canton 3.4 release notes for Splice 0.5.0](https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0),
cited for force-flag history rather than the tested version;
[Canton package management and vetting](https://docs.daml.com/canton/usermanual/packagemanagement.html#understanding-package-vetting);
[Digital Asset developer documentation](https://docs.digitalasset.com/).
