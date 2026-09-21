# Development Fund Proposal: FRED, Daml Development Reload for DPM

> Third edition. Fred is a development loop supervisor. Earlier editions are retained beside this
> file. The copy submitted to `canton-foundation/canton-dev-fund` is authoritative.

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
| Project Duration | ~14 weeks: 9 weeks building the capability, then a 5-week release and adoption window. Under 6 months |
| Label | `daml-tooling` |

---

## Abstract

A Daml developer who makes a breaking change to their model, such as changing a field's type or a
signatory, must restart the participant. That destroys every party and every contract, and
re-seeding returns different party IDs, so scripts, configuration and applications holding the old
ones break. We propose Fred, a DPM component that runs for the length of a development session. Fred
starts the sandbox, seeds it, and watches the project's DARs. When a rebuilt DAR appears, Fred
archives the affected contracts, uploads the new DAR unvetted, swaps the vetted package set in a
single topology transaction, and reseeds. The participant keeps running and every party ID survives.
Contracts are archived and recreated, so contract IDs change. We proved this reload sequence on stock
Canton 3.5.12 with no Canton change and no force flag, and published a machine-checked log for every
claim.

---

## Specification

### 1. Objective

By the end of this grant a Daml developer will start Fred once and work through breaking model
changes without restarting anything. Party IDs hold across every reload, so scripts, configuration
and connected applications keep working. Fred runs on Windows, macOS and Linux, installs with
`dpm add component`, and is documented for developers with no contact with us.

Why now. DPM is new and the Foundation is soliciting components for it under RFP 19, so the extension
point exists and its conventions are being set. The reload sequence is proven and needs nothing from
Canton, making this orchestration rather than protocol work.

### 2. Implementation Mechanics

Fred runs as a single process for the length of a session. It reads `daml.yaml` and
`multi-package.yaml` to find the project's DARs, starts the sandbox, uploads and vets the DARs, runs
the project's Daml Script to seed state, then watches the DAR paths.

When a DAR changes, Fred classifies it with `dpm upgrade-check` before touching the ledger. A
compatible change needs no reload: Fred reports that a version bump is the right answer. A breaking
change runs the reload, and because archival is irreversible Fred confirms first, with a flag to turn
confirmation off for unattended use.

The reload is four steps: archive the contracts of the changed packages, using the signatory
authority the developer holds because they allocated the parties; upload the rebuilt DAR unvetted;
remove the old package IDs and add the new ones in a single topology transaction against the
synchronizer store; reseed. The single transaction is load-bearing. Vetting a new package while the
old one is still vetted produces `KNOWN_PACKAGE_VERSION`, and it is the atomicity that makes a force
flag unnecessary. Two things fail silently, which is why this belongs in a tool rather than a
documentation page: the topology call defaults to a store where it changes nothing and still returns
success, so Fred targets the synchronizer store and asserts the serial advanced; and archival must
precede the swap, because afterwards the old contracts can no longer be archived.

Archiving needs the build that preceded the change, so Fred writes a baseline to disk at startup and
advances it only after a reload verifies. The file is the authority, the in-memory copy a cache, and
Fred refuses if the recorded package IDs no longer match the participant. `fred reload` runs the same
reload once and exits against that baseline, so it works when Fred did not start the participant or a
watcher does not fire. The project declares four hooks as Daml Script: discover, archive, reseed and
verify.

### 3. Architectural Alignment

Fred runs on Windows, macOS and Linux. It ships as a dpm component with no operating-system-specific
scripts, so the component is all a developer installs.

No Canton change, no protocol change, no Ledger API change and no compiler change. Fred uses only
APIs shipping in Canton 3.5.12 and alters nothing about Smart Contract Upgrades or production
vetting. DPM already owns the surrounding pieces: build with multi-package dependency ordering, the
sandbox, script execution and upgrade checking. The work aligns with RFP 19 and with RFP 18 on
integration into SDLCs.

### 4. Backward Compatibility

No backward compatibility impact. Fred is additive and opt-in. It does not change existing Daml
applications, Canton nodes, Ledger API semantics, package upload or package vetting. It operates on a
development participant it owns or has detected to be idle.

---

## Milestones and Deliverables

### Milestone 1: Fred for a Single-Package Project

**Estimated Delivery:** week 5
**Estimated Effort:** ~5 engineer-weeks

A developer starts Fred, edits a single-package model, rebuilds, and carries on with the same party
IDs.

**Deliverables:** Fred, published to an OCI registry under Apache-2.0 and installable with
`dpm add component`; sandbox startup and seeding; DAR watching; change classification through
`dpm upgrade-check`; the confirmation gate before archival; the reload sequence with preflight,
serial and authority verification and checkpointed resume; the durable baseline; `fred reload`; and
documentation.

**Acceptance Criteria:** on a project that is not the proof of concept, a developer starts Fred, makes
a breaking change and continues working, with the participant process unchanged, every declared party
ID identical, and no contracts left on the old package. A committee member or delegate does this from
the published documentation alone. A compatible change produces no archival and no topology
transaction. A breaking change makes no ACS change until confirmed. Median iteration time is at least
60% below the restart-and-reseed baseline over at least ten alternating trials per path. Injected
failures at five boundaries abort with nothing destroyed, or resume and converge.

### Milestone 2: Dependency-Closure Reload

**Estimated Delivery:** week 9
**Estimated Effort:** ~4 engineer-weeks

Real Daml projects are multi-package. Changing one package breaks its dependents, and today the
signal is an error that names nothing.

**Deliverables:** closure computation from the project's multi-package configuration; rebuild in
dependency order and archive in reverse dependency order; every add and remove in one topology
transaction across the closure; a diagnosis naming the package that must be rebuilt, replacing the
current `PACKAGE_SELECTION_FAILED`; and a worked example.

**Acceptance Criteria:** a multi-package project that is not the proof of concept reloads a breaking
change across its full closure in one operation, with dependents working immediately afterwards, and
a committee member reproduces it. Given a closure with dependents omitted, Fred names every one of
them and exits before any change. Closure iteration time meets the Milestone 1 target.

### Milestone 3: Platform Coverage, LocalNet, Documentation and Adoption

**Estimated Delivery:** weeks 10 to 14
**Estimated Effort:** ~5 engineer-weeks

Development finishes with Milestone 2. This is a five-week window in which the release lands and
independent teams use Fred on their own projects.

**Deliverables:** public release and OCI component publication; validation on Windows, macOS and
Linux; a LocalNet validation report covering multiple validators, published whatever it finds; a PQS
pass-through check with a real consumer; a quickstart with an example repository and a recorded
walkthrough; submission of the workflow for Canton and Daml developer documentation and a
presentation to the Daml Language and Developer Tooling SIG; hands-on sessions with independent teams
recruited through that SIG and the Canton Network forum; and six months of maintenance, restoring
compatibility with each new Daml SDK release within 60 days.

**Acceptance Criteria:** Fred completes a reload on all three operating systems, demonstrated by a
committee member on at least one. At least three independent organisations use Fred on their own
project and report in writing whether it changed their development loop, with at least one
multi-package project among them. The adoption report carries measured before-and-after iteration
times. A developer new to Fred completes the quickstart with no LimeChain assistance.

---

## Acceptance Criteria

The Tech & Ops Committee will evaluate completion on ecosystem outcomes rather than artifacts:
independent teams reporting a measurably shorter code-test-debug cycle on their own projects, and the
workflow accepted into, or formally submitted for inclusion in, Canton and Daml developer
documentation. All software is released under Apache-2.0 before any milestone payment.

---

## Funding

**Total Funding Request:** *to be completed before submission.*

The work is 14 engineer-weeks delivered by one engineer over about 14 calendar weeks: 5 for
Milestone 1, 4 for Milestone 2 and 5 for Milestone 3. A further 2 engineer-weeks covers the six-month
maintenance commitment. The effort basis is stated so the figure can be checked against it.

### Payment Breakdown by Milestone

- Milestone 1, Fred for a Single-Package Project: **35%** upon committee acceptance
- Milestone 2, Dependency-Closure Reload: **30%** upon committee acceptance
- Milestone 3, Platform Coverage, LocalNet, Documentation and Adoption: **35%** upon committee
  acceptance and the adoption criteria

Milestone 1 builds the supervisor, the safety gate and the baseline. Milestone 3 matches it because
that is where ecosystem value is demonstrated, and it carries platform coverage and maintenance.

### Volatility Stipulation

The project duration is under 6 months. Should the timeline extend beyond 6 months due to
Committee-requested scope changes, any remaining milestones will be renegotiated to account for
USD/CC price volatility.

---

## Co-Marketing

Upon release, LimeChain will collaborate with the Foundation on a technical blog post, a short
recorded walkthrough of Fred, a presentation to the Daml Language and Developer Tooling SIG, and
submission of the workflow for inclusion in Canton and Daml developer documentation.

---

## Motivation

The code-test-debug cycle is where Daml developers spend their time, and a breaking model change
currently resets it. Restarting the participant destroys every party and every contract. Re-seeding
returns different party IDs, so the real cost is not the restart, which takes seconds, but repairing
every script, configuration file and test fixture that held the old IDs.

The session is awkward today. `dpm sandbox` holds a terminal, so a developer runs it in a second
window or backgrounds it and loses sight of its output. Fred owns the sandbox, so there is one
process, one terminal and one log.

The Foundation's 2026 developer-experience survey points the same way: 41% of respondents named
environment setup and node operations as the task that took them longest, and local development
frameworks were rated Critical.

Existing test tooling does not reach this. `dpm test` and the Daml Studio script runner run against
the compiler's own in-memory ledger, with no participant and no topology, so they cannot tell you
whether a new model can replace the old one on a participant that is already running.

Measured on the shell prototype, a reload reaches a verified seeded state in a median 18.5 seconds
against 30.6 seconds to restart and reseed. That prototype launches five JVM processes per reload.
Fred launches none, because it is already running.

---

## Rationale

A supervisor rather than a command. A tool that owns the session can start the sandbox, hold the
build that preceded a change, and act the instant a rebuild appears. The developer runs one thing in
one terminal. `fred reload` exposes the same operation where Fred does not own the participant.

A runbook cannot carry this. Documentation cannot verify a topology serial, check per-contract
authority before archiving, or resume a half-finished reload.

---

## About the Team

LimeChain has built and shipped blockchain infrastructure and developer tooling since 2017.

*Track record: **TBD before submission**. Named prior work, ecosystems and engagement durations to be
listed here.*

How we work is visible in the evidence base. We set out to prove a result and then tried to disprove
it: we found a mislabelling defect in our own harness, built a control that would fail if the harness
could not tell the two configurations apart, re-ran the matrix against it, and published every log
including the correction. The proof of concept also surfaced six defects in the shipped toolchain,
which we are filing with Digital Asset.

---

## Appendix: Mechanism and Evidence

Public repository: <https://github.com/LimeChain/canton-dev-reload> (Apache-2.0), pinned at
[`harness-v13`](https://github.com/LimeChain/canton-dev-reload/tree/harness-v13). Tags there never
move, so the link is stable; `main` is not and should not be cited.

**What the evidence proves.** Fourteen committed runs establish one sequence: archive, upload the
rebuilt DAR unvetted, one `propose_delta` against the synchronizer store removing the old package IDs
and adding the new ones, then reseed. The unforced swap succeeds with contracts archived first. A
control pair proves the harness can tell the two force settings apart, which is what makes the
headline falsifiable. A dependent left unrebuilt fails. A full closure swaps in one transaction.
Party IDs survive, and ordering decides whether contracts are stranded. Every log carries a
provenance header and assertions that exit non-zero on failure.

**What it does not prove.** Nothing here covers supervision, file watching, sandbox lifecycle or
cross-platform behaviour. That is new engineering. The open question was whether a package can be
swapped in place on a running participant with no force flag, and the logs answer it. The supervisor
is ordinary tooling around a proven core.

[`evidence/INDEX.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v13/evidence/INDEX.md)
maps each claim to its log and states what the runs do not establish.
[`docs/design-note.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v13/docs/design-note.md)
specifies the reload core, the baseline lifecycle and the hook contract, which is what `fred reload`
runs; the supervisor layer is not specified there yet.

References: [Canton 3.4 release notes](https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0),
for force-flag history rather than the tested version;
[Canton package vetting](https://docs.daml.com/canton/usermanual/packagemanagement.html#understanding-package-vetting);
[Digital Asset developer documentation](https://docs.digitalasset.com/).
