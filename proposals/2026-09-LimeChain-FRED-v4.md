# Development Fund Proposal: FRED, Daml Development Reload for DPM

> Fourth edition. The one-shot command ships first, the live sandbox is built on it, and PQS becomes
> a managed component. Earlier editions are retained beside this file. The copy submitted to
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
| Project Duration | ~17 weeks of delivery, followed by a 6-month maintenance term |
| Label | `daml-tooling` |

---

## Abstract

A Daml developer who makes a breaking change to their model, such as changing a field's type, must
restart the participant. That destroys every party and every contract, and re-seeding returns
different party IDs, so scripts, configuration and applications holding the old ones break.
We propose Fred, a DPM component that replaces the restart with an in-place reload: archive the
affected contracts, upload the rebuilt DAR unvetted, swap the vetted package set in one topology
transaction, then reseed. The participant keeps running and every party ID survives. Contracts are
archived and recreated, so contract IDs change. Fred ships first as a command, then as a supervisor
that owns the sandbox for a session and reloads when a rebuilt DAR appears. We proved the reload
sequence on stock Canton 3.5.12 with no Canton change and no force flag, and published a
machine-checked log for every claim.

---

## Specification

### 1. Objective

By the end of this grant a Daml developer will work through breaking model changes without restarting
anything. Party IDs hold across every reload, so scripts, configuration and connected applications
keep working. The capability runs on Windows, macOS and Linux and installs with `dpm add component`.

Why now. DPM is new and the Foundation is soliciting components for it under RFP 19, so the extension
point exists and its conventions are being set. The reload sequence is proven and needs nothing from
Canton, making this orchestration rather than protocol work.

### 2. Implementation Mechanics

The reload is four steps: archive the contracts of the changed packages, using the signatory authority
the developer holds because they allocated the parties; upload the rebuilt DAR unvetted; remove the
old package IDs and add the new ones in one topology transaction against the synchronizer store;
reseed. The single transaction is load-bearing. Vetting a new package while the old is still vetted
produces `KNOWN_PACKAGE_VERSION`, and the atomicity is what makes a force flag unnecessary.

Two things fail silently, which is why this belongs in a tool rather than a documentation page. The
topology call defaults to a store where it changes nothing and still returns success, so the component
targets the synchronizer store and asserts the serial advanced. And archival must precede the swap,
because afterwards the old contracts can no longer be archived. Archiving needs the build that
preceded the change, so the component keeps a durable baseline on disk, advanced only after a reload
verifies, and the project declares four hooks as Daml Script: discover, archive, reseed and verify.

`fred reload` performs that sequence once and exits, against a participant the developer started.
Fred adds a supervisor around it: it starts the sandbox, seeds it, watches the DARs, and classifies
each change with `dpm upgrade-check` before touching the ledger. A compatible change needs no reload.
A breaking change follows the policy set at startup: `confirm`, the default, asks before archiving;
`notify` reports and waits; `auto` runs without prompting, for CI and for a tight loop. Both paths
read the same baseline.

`fred reset` rebuilds the session from scratch, the startup sequence re-invoked. Unlike a reload it
discards party IDs, and says so first.

### 3. Architectural Alignment

Fred runs on Windows, macOS and Linux and ships as a dpm component with no operating-system-specific
scripts, so the component is all a developer installs.

No Canton change, no protocol change, no Ledger API change and no compiler change. Fred uses only APIs
shipping in Canton 3.5.12 and alters nothing about Smart Contract Upgrades or production vetting. DPM
already owns the surrounding pieces: build with dependency ordering, the sandbox, script execution and
upgrade checking. The work aligns with RFP 19 and RFP 18.

### 4. Backward Compatibility

No backward compatibility impact. Fred is additive and opt-in. It does not change existing Daml
applications, Canton nodes, Ledger API semantics, package upload or package vetting. It operates on a
development participant it owns or has detected to be idle.

---

## Milestones and Deliverables

### Milestone 1: The Reload Command

**Estimated Delivery:** week 4
**Estimated Effort:** ~4 engineer-weeks

`fred reload` performs a breaking-change reload on a single-package project against a participant the
developer is already running. This is the capability everything else is built on, and it remains the
fallback once the supervisor exists.

**Deliverables:** the component, published to an OCI registry under Apache-2.0 and installable with
`dpm add component`; the hook interface; the durable baseline; the preflight and commit sequence with
serial and authority verification and checkpointed resume; change classification; and documentation.

**Acceptance Criteria:** on a project that is not the proof of concept, a developer completes a
breaking-change reload with the participant process unchanged, every declared party ID identical, and
no contracts left on the old package. A committee member does this from the published documentation
alone, with the component verified on all three operating systems. Median iteration time is at least
40% below the restart-and-reseed baseline, over at least ten alternating trials per path from a reset
ledger, with the baseline re-measured on the same machine. Injected failures at five boundaries abort
with nothing destroyed, or resume and converge.

### Milestone 2: Multi-Package Projects

**Estimated Delivery:** week 7
**Estimated Effort:** ~2.5 engineer-weeks

Real Daml projects are several packages that depend on each other, and compiled Daml embeds the
package ID of its dependencies. Change one and its dependents no longer fit.

**Deliverables:** closure computation from the project's multi-package configuration; rebuild in
dependency order and archive in reverse; every add and remove in one topology transaction; a diagnosis
naming the package that must be rebuilt, replacing the current `PACKAGE_SELECTION_FAILED`; and a
worked example.

**Acceptance Criteria:** a multi-package project that is not the proof of concept reloads across its
full closure in one operation, with dependents working immediately afterwards, reproduced by a
committee member. Given a closure with dependents omitted, the tool names every one of them and exits
before any change. Closure iteration time meets the Milestone 1 threshold.

### Milestone 3: The Live Sandbox

**Estimated Delivery:** week 12
**Estimated Effort:** ~5 engineer-weeks

Fred runs for the length of a session, so the developer runs one thing in one terminal.

**Deliverables:** sandbox startup and seeding; DAR watching; the `confirm`, `notify` and `auto`
policy; the reload triggered from the watcher, sharing Milestone 1's core and baseline; and
`fred reset`.

**Acceptance Criteria:** a developer starts Fred, edits a model, rebuilds, and continues working
without restarting, on all three operating systems. The default policy is `confirm`, asserted rather
than described: a compatible change produces no archival and no topology transaction, and a breaking
change makes no ACS change until the developer confirms. A reset warns that party IDs will be
discarded. Median iteration time is at least 50% below the restart-and-reseed baseline under the
Milestone 1 protocol, with the baseline re-measured on the same machine.

### Milestone 4: PQS, Release and Adoption

**Estimated Delivery:** week 17
**Estimated Effort:** ~5 engineer-weeks, plus 2 for maintenance

PQS indexes the ledger into Postgres so applications can query with SQL. A reload leaves it holding
rows for contracts that no longer exist, and removing the old DAR leaves history it cannot read.

**Deliverables:** PQS lifecycle, started after vetting and stopped on shutdown when configured;
retention of old DARs while PQS is configured, so history stays readable and a re-ingest remains
possible; synchronisation, where Fred waits for PQS to catch up before reporting a reload verified;
and `fred reset --pqs`, which empties the datastore and re-ingests, and which a ledger reset also
triggers because a fresh sandbox restarts offsets.

Also: public release and OCI publication; a LocalNet validation report covering multiple validators,
published whatever it finds; a quickstart with an example repository; submission of the workflow for
Canton and Daml developer documentation; and six months of maintenance, restoring compatibility with
each new Daml SDK release within 60 days.

**Acceptance Criteria:** after a breaking reload with PQS attached, a query returns the new shape and
no rows from the old package, and Fred does not report the reload verified until PQS has caught up. No
reset leaves Fred reporting a stale PQS as synchronised, and Fred refuses with a stated reason when a
complete re-ingest is impossible. At least three independent organisations use Fred on their own
project and report in writing whether it changed their development loop, one of them multi-package.
The adoption report carries measured before-and-after iteration times, and a developer new to Fred
completes the quickstart with no LimeChain assistance.

---

## Acceptance Criteria

The Tech & Ops Committee will evaluate completion on ecosystem outcomes rather than artifacts:
independent teams reporting a measurably shorter code-test-debug cycle on their own projects, and the
workflow submitted for Canton and Daml developer documentation. Every milestone is verified on all
three operating systems, and all software is released under Apache-2.0 before any payment.

---

## Funding

**Total Funding Request:** *to be completed before submission.*

Delivery is 16.5 engineer-weeks by one engineer over about 17 calendar weeks: 4 for Milestone 1, 2.5
for Milestone 2, 5 for Milestone 3 and 5 for Milestone 4. A further 2 cover the six-month maintenance
term that follows, giving **18.5 engineer-weeks** in total, stated so the figure can be checked
against it.

### Payment Breakdown by Milestone

- Milestone 1, The Reload Command: **25%** upon committee acceptance
- Milestone 2, Multi-Package Projects: **20%** upon committee acceptance
- Milestone 3, The Live Sandbox: **25%** upon committee acceptance
- Milestone 4, PQS, Release and Adoption: **30%** upon committee acceptance and the adoption criteria

Milestone 4 carries the largest share because it holds adoption evidence and maintenance.

### Volatility Stipulation

The delivery period is under 6 months, and the six-month maintenance term follows it. Should delivery
extend beyond 6 months due to Committee-requested scope changes, any remaining milestones will be
renegotiated to account for USD/CC price volatility.

---

## Co-Marketing

Upon release, LimeChain will collaborate with the Foundation on a technical blog post, a recorded
walkthrough of Fred, and a presentation to the Daml Language and Developer Tooling SIG.

---

## Motivation

The code-test-debug cycle is where Daml developers spend their time, and a breaking model change
resets it. The real cost is not the restart, which takes seconds, but repairing every script,
configuration file and test fixture that held the old party IDs.

The session is awkward today. `dpm sandbox` holds a terminal, so a developer backgrounds it and
loses sight of its output. Fred owns the sandbox, so there is one process and one log.

The Foundation's 2026 developer-experience survey points the same way: 41% of respondents named
environment setup and node operations as the task that took them longest.

Existing test tooling does not reach this. `dpm test` and the Daml Studio script runner run against
the compiler's own in-memory ledger, with no participant and no topology, so they cannot tell you
whether a new model replaces the old one on a running participant.

Measured on the shell prototype, a reload reaches a verified seeded state in a median 18.5 seconds
against 30.6 seconds to restart and reseed, a 39.5% reduction. The prototype spawns a Canton console
twice per reload, which the component does in its own process instead.

---

## Rationale

The command first, the supervisor after. The reload is the part our evidence covers and the part
everything else depends on, so it ships as Milestone 1 and stays available afterwards for the cases
where Fred does not own the participant. The supervisor is what makes it a development loop.


---

## About the Team

LimeChain has built and shipped blockchain infrastructure and developer tooling since 2017.

*Track record: **TBD before submission**. Named prior work, ecosystems and engagement durations to be
listed here.*

How we work is visible in the evidence base. We set out to prove a result and then tried to disprove
it: we found a mislabelling defect in our own harness, built a control that would fail if it could not
tell the two configurations apart, re-ran the matrix against it, and published every log including the
correction. The proof of concept also surfaced six defects in the shipped toolchain,
filed with Digital Asset.

---

## Appendix: Mechanism and Evidence

Public repository: <https://github.com/LimeChain/canton-dev-reload> (Apache-2.0), pinned at
[`harness-v14`](https://github.com/LimeChain/canton-dev-reload/tree/harness-v14). Tags there never move, so
the link is stable; `main` should not be cited.

**What the evidence establishes.** Fourteen committed runs cover one sequence: archive, upload the
rebuilt DAR unvetted, one `propose_delta` against the synchronizer store removing the old package IDs
and adding the new ones, then reseed. The unforced swap succeeds with contracts archived first. A
control pair proves the harness can tell the two force settings apart, which is what makes the
headline falsifiable. A dependent left unrebuilt fails, a full closure swaps in one transaction, party
IDs survive, and ordering decides whether contracts are stranded. Every log carries a provenance
header and assertions that exit non-zero on failure.

**What it does not establish.** It validates the mechanism the first milestone is built on, not the
milestone itself. The hook interface, the durable baseline, checkpointed resume, cross-platform
behaviour and both iteration-time thresholds are new work, as are the supervisor, the file watching
and the PQS integration. PQS is designed here and unproven: our evidence substituted a polling
JSON-API consumer, and Milestone 4 requires it demonstrated against a real PQS and Postgres.

[`evidence/INDEX.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v14/evidence/INDEX.md)
maps each claim to its log and states what the runs do not establish.
[`docs/design-note.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v14/docs/design-note.md)
specifies the reload core, the baseline lifecycle and the hook contract.

References: [Canton 3.4 release notes](https://blog.digitalasset.com/developers/release-notes/canton-3.4-release-notes-for-splice-0.5.0),
cited for force-flag history rather than the tested version, and
[Canton package vetting](https://docs.daml.com/canton/usermanual/packagemanagement.html#understanding-package-vetting).
