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
| Project Duration | ~12 weeks of delivery, followed by a 6-month maintenance term |
| Label | `daml-tooling` |

---

## Abstract

A Daml developer who makes a breaking change to their model, such as changing a field's type, must
restart the participant. That destroys every party and every contract, and re-running setup returns
different party IDs, so anything holding the old ones breaks. We propose Fred, a DPM component that
replaces the restart with an in-place reload: archive the affected contracts, upload the rebuilt DAR
unvetted, swap the vetted package set in one topology transaction, then run setup. The participant
keeps running and every party ID survives, though contracts are archived and recreated, so contract
IDs change. Fred ships first as a command, then as a supervisor. We proved the reload sequence on
stock Canton 3.5.12 with no Canton change and no force flag, and published a machine-checked log for
every claim.

---

## Motivation

The code-test-debug cycle is where Daml developers spend their time, and a breaking model change
resets it. The real cost is not the restart, which takes seconds, but repairing every script,
configuration file and test fixture that held the old party IDs. The session is awkward too:
`dpm sandbox` holds a terminal, so a developer backgrounds it and loses its output.

The Foundation's 2026 developer-experience survey points the same way: 41% of respondents named
environment setup and node operations as the task that took them longest.

Existing test tooling does not reach this: `dpm test` and the Daml Studio script runner use the
compiler's own in-memory ledger, with no participant and no topology.

Measured on the shell prototype, a reload reaches a verified seeded state in a median 18.5 seconds
against 30.6 seconds to restart and set up again, a 39.5% reduction. The prototype spawns a Canton
console twice per reload, which the component does in its own process. The appendix maps every claim
in this proposal to the log behind it.

---

## Rationale

The command first, the supervisor after. The reload is the part our evidence covers and everything
else depends on, so it ships first and stays available where Fred does not own the participant. The
supervisor is what makes it a development loop.

We removed our own protocol ask. Our internal RFC proposed a new Canton operation. Building the proof
of concept showed it unnecessary, and we would rather report that than request surface we do not
need.

---

## Specification

### 1. Objective

By the end of this grant a Daml developer will work through breaking model changes without restarting
anything. Party IDs hold across every reload, so scripts, configuration and connected applications
keep working. It runs on Windows, macOS and Linux and installs with `dpm add component`.

Why now. DPM is new and the Foundation is soliciting components under RFP 19, so the conventions are
being set now. The reload sequence is proven and needs nothing from Canton, making this orchestration
rather than protocol work.

### 2. Implementation Mechanics

The reload is four steps: archive the contracts of the changed packages, using the signatory authority
the developer holds because they allocated the parties; upload the rebuilt DAR unvetted; remove the
old package IDs and add the new ones in one topology transaction against the synchronizer store; run
setup. The single transaction is load-bearing: vetting a new package while the old is still vetted
produces `KNOWN_PACKAGE_VERSION`, and that atomicity is what makes a force flag unnecessary.

Two things fail silently, which is why this belongs in a tool rather than a documentation page. The
topology call defaults to a store where it changes nothing and still returns success, so the component
targets the synchronizer store and asserts the serial advanced, and archival must precede the swap
because afterwards the old contracts can no longer be archived. Archiving needs the build that
preceded the change, so the component keeps a durable baseline on disk, advanced only after a reload
verifies, and the project declares four hooks as Daml Script: discover, archive, setup and verify,
specified in full in the design note the appendix links.

`fred reload` performs that sequence once and exits, against a participant the developer started.
Fred adds a supervisor around it: it starts the sandbox, runs setup, watches the DARs, and classifies
each change with `dpm upgrade-check` before touching the ledger. A compatible change needs no reload.
A breaking change follows the policy: `confirm`, the default, asks before archiving; `notify` reports
and waits; `auto` runs without prompting. Both paths read the same baseline.

Preflight exhausts the work that can be moved ahead of the irreversible phase, so a failure there
leaves the ledger untouched. Later steps can still fail. After a failed commit Fred stops acting on
file changes until the developer resumes or resets, and because the checkpoint is durable it also
refuses to watch at startup while a commit is incomplete.

Behaviour is declared in project configuration with command-line overrides. Hook declarations are
committed with the project. Interaction preferences stay with the developer. Fred prints its effective
configuration at startup, so a setting that destroys data is never out of sight. Fred is interactive:
a reload or a reset can be triggered without leaving the session. A reset re-invokes the startup
sequence and, unlike a reload, discards party IDs, which it says first.

### 3. Architectural Alignment

Fred ships as a dpm component with no operating-system-specific scripts, so the component is all a
developer installs.

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

`fred reload` performs a breaking-change reload against a participant the developer is already
running. Real Daml projects are several packages, and compiled Daml embeds the package ID of its
dependencies, so changing one leaves its dependents no longer fitting. The command handles the whole
closure. This is what everything else is built on, and it remains the fallback once the supervisor
exists.

**Deliverables:** the component, published to an OCI registry under Apache-2.0 and installable with
`dpm add component`, as the first public release; the hook interface; the durable baseline; the
preflight and commit sequence with serial and authority verification and checkpointed resume; closure
computation, rebuilt in dependency order and archived in reverse, with every add and remove in one
topology transaction; a diagnosis naming the package that must be rebuilt; and documentation with a
worked multi-package example.

**Acceptance Criteria:** on a project that is not the proof of concept, a developer completes a
breaking-change reload with the participant unchanged, every declared party ID identical, and no
contracts left on the old package. A multi-package project reloads across its full closure in one
operation with dependents working afterwards, and a closure with dependents omitted names every one
and exits before any change. A committee member does both from the published documentation alone,
with the component verified on all three operating systems. Median iteration time is at least 40%
below the restart baseline, over at least ten alternating trials per path from a reset ledger, with
the baseline re-measured on the same machine. Injected failures at five boundaries abort with nothing
destroyed, or resume and converge.

### Milestone 2: The Live Sandbox

**Estimated Delivery:** week 7
**Estimated Effort:** ~3 engineer-weeks

Fred runs for the length of a session, so the developer runs one thing in one terminal.

**Deliverables:** sandbox startup and setup; DAR watching; the `confirm`, `notify` and `auto` policy
with project and user configuration; the reload triggered from the watcher, sharing Milestone 1's core
and baseline; and reset from the session.

**Acceptance Criteria:** a developer starts Fred, edits a model, rebuilds, and continues working
without restarting, on all three operating systems. Defaults are asserted rather than described, being
what a developer meets on first run: the policy is `confirm`, a compatible change produces no archival
and no topology transaction, and a breaking change makes no ACS change until confirmed. After a failed
commit Fred acts on no further file change, and a restart with an incomplete checkpoint refuses to
watch until resumed or reset. Fred reports its effective configuration at startup, and a reset warns
that party IDs will be discarded. Median iteration time is at least 50% below the restart baseline
under the Milestone 1 protocol.

### Milestone 3: PQS

**Estimated Delivery:** week 9
**Estimated Effort:** ~2 engineer-weeks

PQS indexes the ledger into Postgres for SQL queries. A reload leaves it holding rows for contracts
that no longer exist, and removing the old DAR leaves history it cannot read.

**Deliverables:** PQS lifecycle, started after vetting and stopped on shutdown when configured;
retention of old DARs while PQS is configured, so history stays readable and a re-ingest remains
possible; synchronisation, where Fred waits for PQS to catch up before reporting a reload verified;
`fred reset --pqs`, which a full reset also covers; and a LocalNet validation report covering multiple
validators, published whatever it finds.

**Acceptance Criteria:** after a breaking reload with PQS attached, a query returns the new shape and
no rows from the old package, and Fred does not report the reload verified until PQS has caught up. No
reset leaves Fred reporting a stale PQS as synchronised, and Fred refuses when a complete re-ingest is
impossible. The LocalNet report is published.

### Milestone 4: Adoption

**Estimated Delivery:** week 12
**Estimated Effort:** ~2 engineer-weeks, plus 2 for maintenance

The component is public from Milestone 1, so teams use it while the rest is built. This milestone is
accepted on what they report.

**Deliverables:** a quickstart with an example repository; submission of the workflow for Canton and
Daml developer documentation and a presentation to the Daml Language and Developer Tooling SIG;
hands-on sessions with independent teams recruited through that SIG and the Canton Network forum; the
adoption report; and six months of maintenance, restoring compatibility with each new SDK release
within 60 days.

**Acceptance Criteria:** at least three independent organisations use Fred on their own project and
report in writing whether it changed their development loop, one of them multi-package. The adoption
report carries measured before-and-after iteration times, and a developer new to Fred completes the
quickstart unaided.

---

## Acceptance Criteria

The Tech & Ops Committee will evaluate completion on ecosystem outcomes rather than artifacts:
independent teams reporting a measurably shorter code-test-debug cycle on their own projects, and the
workflow submitted for Canton and Daml developer documentation. Every milestone is verified on all
three operating systems, and all software is released under Apache-2.0 before any payment.

---

## Funding

**Total Funding Request:** *to be completed before submission.*

Delivery is 11 engineer-weeks by one engineer over about 12 calendar weeks: 4, 3, 2 and 2 across the
milestones. A further 2 cover the six-month maintenance term, giving **13 engineer-weeks** in total,
stated so the figure can be checked.

### Payment Breakdown by Milestone

- Milestone 1, The Reload Command: **30%**
- Milestone 2, The Live Sandbox: **25%**
- Milestone 3, PQS: **15%**
- Milestone 4, Adoption: **30%**, on acceptance and the adoption criteria

The split tracks effort against the 13 engineer-week total, with Milestone 4 counting its two weeks of maintenance.

### Volatility Stipulation

The delivery period is under 6 months, and the six-month maintenance term follows it. Should delivery
extend beyond 6 months due to Committee-requested scope changes, any remaining milestones will be
renegotiated to account for USD/CC price volatility.

---

## Co-Marketing

As part of Milestone 4, LimeChain will create and publish the release assets below. Foundation
amplification is requested, not assumed, and remains subject to the Foundation's editorial and
channel approvals:

- A technical article, "Changing a Daml model without restarting Canton, and why it needs no force
  flag," explaining the developer problem, safety model, implementation boundaries and supporting
  evidence.
- A short recorded walkthrough showing a complete reload, the pre-flight and failure-safety checks,
  recovery behavior and the resulting developer workflow.
- A live walkthrough and Q&A for the Daml Language & Developer Tooling SIG, subject to SIG
  scheduling, with the recording or slides published where permitted.
- A documentation contribution covering installation, supported scenarios, limitations and
  troubleshooting, plus a post-release update summarizing repository activity, user feedback and
  adoption evidence gathered during Milestone 4.

---

## About the Team

LimeChain is a blockchain engineering company founded in 2017. The evidence below is selected for
direct funding with Daml Development Reload: SDK and CLI maintenance, local development, debugging
and test tooling, package and dependency workflows, protocol-facing engineering, public releases,
documentation, adoption and long-term maintenance.

**Canton Network:** LimeChain members were named among Canton's inaugural Community Tech Partners, an
invite-only volunteer developer-enablement program. For this proposal, LimeChain built and published
an evidence-backed development-reload prototype tested on Canton 3.5.12 and dpm-sdk 3.5.5. Separately,
LimeChain did R&D on a few initiatives including an open Daml Package Registry architecture as a dpm
extension, direct Canton/Daml toolchain work, package-lifecycle analysis and public developer
enablement, x402, Metamask adapters, while building several projects for clients on Canton around
tokenization of financial instruments.

**Hedera:** key development partner, ongoing for more than five years. Hedera attributes the JSON-RPC
Relay, Java SDK, Local Node environment and EVM-compatibility work including HIP-415 and HIP-376 to
LimeChain. Relevance: sustained delivery and maintenance of SDKs, local-development environments,
compatibility layers and public infrastructure.

**Solana Foundation:** grant-funded and commissioned developer tooling. A Solana Foundation grant
supported Zest, LimeChain's open-source Rust code-coverage CLI; the original repository now
transparently points to its successor. LimeChain's tooling catalogue describes Gimlet, its maintained
VS Code debugger, as created for the Foundation. In September 2026, a LimeChain-authored contribution
adding Kamino scenario support was merged into the Foundation-owned Surfpool repository.

**NEAR ecosystem:** Limechain has been a Wallet Selector maintainer and JavaScript tooling
Contributor; added near-workspaces-based CI to near-api-js and security improvements to near-sdk-js;
worked inside established SDK repositories on CI, integration testing, security and everyday developer
workflows.

**Polkadot ecosystem:** Polkadot Pioneers Prize-funded protocol implementation. Fruzhin is LimeChain's
Java implementation of the Polkadot Host. Its public development branch reports light-client,
full-node and authoring-node support. It has relevance to protocol and runtime engineering, state
synchronization, node lifecycle and interoperability testing with clear production-readiness
boundaries.

**Additional open-source developer tooling:** ecosystem contributions; LimeChain's stylus-toolkit
provides reusable Rust building blocks for Arbitrum Stylus, while Matchstick provides a Rust-based
unit-testing framework for The Graph subgraphs. The direct relevance covers reusable libraries,
package integration, sandboxed testing, release workflows and developer-facing documentation across
different runtimes.

**Evidence discipline.** The reload prototype reflects how LimeChain works: the team found a
mislabeling defect in its own harness, corrected it, added a control that would fail if the harness
could not distinguish the configurations being compared, re-ran the full matrix and published the logs
and correction. The same work surfaced six toolchain defects and documented them separately.

**Delivery and maintenance.** One senior engineer will lead implementation, supported by protocol and
developer-tooling reviewers. LimeChain owns the component implementation, tests, release engineering,
documentation, adoption support, Committee reporting and six months of post-release maintenance.
Milestone acceptance remains tied to a clean-environment installation, independent execution of the
reference flow and the adoption evidence defined in this proposal.

---

## Appendix: Mechanism and Evidence

Public repository: <https://github.com/LimeChain/canton-dev-reload> (Apache-2.0), pinned at
[`harness-v20`](https://github.com/LimeChain/canton-dev-reload/tree/harness-v20). Tags there never move, so
the link is stable, and `main` should not be cited.

**What the evidence establishes.** Fourteen committed runs cover one sequence: archive, upload
unvetted, one `propose_delta` against the synchronizer store removing the old package IDs and adding
the new ones, then run setup. The unforced swap succeeds with contracts archived first. A control
pair proves the harness can tell the two force settings apart, which is what makes the headline
falsifiable. A dependent left unrebuilt fails, a full closure swaps in one transaction, party IDs
survive, and ordering decides whether contracts are stranded. Every log carries a provenance header
and assertions that exit non-zero on failure.

**What it does not establish.** It validates the mechanism the first milestone is built on, not the
milestone itself. The hook interface, the durable baseline, checkpointed resume, cross-platform
behaviour and both thresholds are new work, as are the supervisor, the file watching and PQS. PQS is
designed here and unproven: our evidence substituted a polling JSON-API consumer, and Milestone 3
requires it demonstrated against a real PQS and Postgres.

[`evidence/INDEX.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v20/evidence/INDEX.md)
maps each claim to its log and states what the runs do not establish.
[`docs/design-note.md`](https://github.com/LimeChain/canton-dev-reload/blob/harness-v20/docs/design-note.md)
specifies the reload core, the baseline lifecycle and the hook contract.
