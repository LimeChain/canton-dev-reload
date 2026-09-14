# Dev Model Reload — POC Results

All results below are **observed output**, not inference. Verbatim error strings are quoted.
Tested against **Canton 3.5.12 / dpm-sdk 3.5.5**, OpenJDK 21.

---

## Headline

There are **two** ways to change a running model, and which one you need depends only on
whether your change is a valid upgrade.

| Your change | Approach | Canton changes needed |
|---|---|---|
| **compatible** (add optional field, new choice) | bump the version — `1.0.0` → `1.0.1` | **none.** Already shipped and supported |
| **incompatible** (type change, drop field, change signatory) | keep the version — archive, then replace | **none for the loop itself** |

Both work today. The only unsolved problem is **reclaiming storage** afterwards.

---

## Approach 1 — bump the version (compatible changes)

Tested against a running, seeded `mirrors 1.0.0`:

| Upload while 1.0.0 is live and holds contracts | Result |
|---|---|
| `1.0.1`, compatible (added `Optional` field) | **ACCEPTED** — live, no restart, no force flag |
| `1.0.2`, incompatible (`Text` → `Int`) | **REJECTED** — `NOT_VALID_UPGRADE_PACKAGE(8,2a24e61f): Upgrade checks indicate that 758138aee9c9 (mirrors v1.0.2) cannot be an upgrade of 8ae31785db7a…` |

After the compatible upload, **1.0.0 and 1.0.1 were both vetted simultaneously**. Nothing was
archived. Nothing restarted.

### Dependents do NOT need rebuilding

Verified with a real two-package project — `items` (A) and `holders` (B), where B's template
holds a `ContractId Item`, i.e. a cross-package reference, and a choice that `fetch`es it:

```
UPLOAD items 1.0.1 => ACCEPTED
ACS Items:Item      pkg=d908e8a150de    <- NEW contracts created at 1.0.1 automatically
ACS Holders:Holder  pkg=92c6c3f57ebf    <- holders never rebuilt
PEEK holders=1   PEEK label=first       <- B fetched from A successfully
```

Canton resolves templates by package **name** and picks the newest compatible version, so B's
references follow A's upgrade by themselves. A script compiled against `items 1.0.0` even
created new contracts at `1.0.1`. **This is Smart Contract Upgrades working as designed and it
needs nothing from us.**

### Forcing an incompatible bump: possible, and a trap

`ForceFlag.AllowVetIncompatibleUpgrades` *will* vet an incompatible bumped version:

```
FORCE_VET_INCOMPATIBLE_BUMP => SUCCEEDED
   mirrors 1.0.1  510abec1a117  VETTED    (Int)
   mirrors 1.0.0  c17b5cb16a9d  VETTED    (Text)
```

But the result is unusable in both directions:

```
create old-shape contract:
  COMMAND_PREPROCESSING_FAILED(8,feab63c0): mismatching type: Int64 and value: Text(hello-from-the-old…)
read / archive existing contracts:
  INTERPRETATION_UPGRADE_ERROR_TRANSLATION_FAILED(8,5dda1e81): Interpretation error: Error: Translation…
```

Once two **incompatible** versions share a package name, name-based resolution picks the
newest and everything built against the old shape breaks — and critically **you can no longer
even archive the old contracts**, so you cannot clean up. This is strictly worse than
Approach 2. No event or flag can fix it: existing contracts physically store `Text`, and a
package expecting `Int` cannot read those bytes. It is a data-shape impossibility, not a
permissions check.

---

## Approach 2 — keep the version (incompatible changes)

The working loop, verified end to end:

```
1. archive the old contracts        (ordinary Daml Archive, as the signatories)
2. upload the new package UNVETTED
3. swap the vetted set             (one topology transaction: adds=[new], removes=[old])
4. reseed
5. dars.remove(old)                (optional)
```

Result:

```
RELOAD orphanedContracts=0
PASS  sandbox PID unchanged
PARTY reused  Alice = Alice::1220712a44fb…
BEFORE: 1.0.0/c17b5cb16a9d   1.0.0/dba33b18bff3
REMOVE_OLD => SUCCEEDED
AFTER:  1.0.0/dba33b18bff3
```

One `mirrors 1.0.0` remains, carrying the new types. Same process, same party IDs, nothing
restarted, zero leftovers. **No Canton change, no force flag, no repair tooling.**

### Order is critical — archive FIRST

Archiving must happen while the old package is still the only vetted one. Archiving *after*
the swap fails both ways:

- once the old package is unvetted, nothing from it can be exercised
- re-vetting both to work around that hits upgrade name-resolution:
  `QueryACS failed: Preprocessing(TypeMismatch(TBuiltin(BTText),Int64(42)…))`

### The force flag is NOT required

Single-operation tests from a clean state, old package vetted with 2 live contracts:

| Operation | Force flag | Result |
|---|---|---|
| `propose_delta(adds=[new], removes=[old])` | **none** | **SUCCEEDED** — old out, new in |
| `propose_delta(removes=[old])` | **none** | **SUCCEEDED** — contracts untouched |

`KNOWN_PACKAGE_VERSION` evaluates the **resulting** vetted set, and an atomic swap never
produces a state with two same-name/same-version packages. The force flag is only needed to
*add* a second version while keeping the first — which we do not want.

### Unvetting: what we rely on vs what we merely observed

Unvetting is permitted if **either** (a) no active contracts reference the package, or (b) some
other vetted package can still interpret them.

**The loop above satisfies (a)** — archiving happens first, so the old package has zero active
contracts when it is unvetted. Nothing here depends on (b).

Separately, we tested the unsafe path: unvetting a package that still had 2 live contracts, with
no compatible version anywhere, so neither (a) nor (b) held.

```
PRE  v1Vetted=true  contracts=2
RESULT unvet-noforce => SUCCEEDED
POST v1Vetted=false contracts=2
```

It succeeded, unforced, leaving contracts nothing can interpret. **And this is not a sandbox
relaxation** — the participant was on **stable protocol version 35**:

```
stable = List(34, 35)     alpha = List(dev)     beta = List()     latest = 35
PSID   = synchronizer-1::1220e41755d3…::35-0
```

with no `alpha-version-support` / `beta-version-support` / dev flags set. Canton ships a separate
`sandbox/alpha.conf` for relaxed behaviour and we were not using it, so a production participant
should behave the same. Worth reporting to Canton as a possible gap; **not** something this
proposal depends on.

### Dependents MUST be rebuilt

The mirror image of Approach 1. Same two-package project, A replaced incompatibly at the same
version, B not rebuilt:

```
SWAP items oldA=f598c7e1de1b  newA=04d8ea17faef   (holders NOT rebuilt)
PEEK holders=1
FAILURE: PACKAGE_SELECTION_FAILED(9,5a638620): No synchronizers satisfy the topology requirements
```

B can still see its contracts but cannot exercise anything. B was compiled expecting the old
shape; the package it needs is no longer vetted; and an incompatible change offers no upgrade
relationship to follow. So the loop must operate on the whole **dependency closure**:

```
rebuild A, then B against the new A       (dpm already builds in dependency order)
archive B's contracts, then A's           (B first -- B references A)
upload new A and new B, both unvetted
one topology transaction: adds=[newA,newB]  removes=[oldA,oldB]
reseed
```

---

## The one unsolved problem: reclaiming storage

Archiving removes contracts from the active set — nothing queries them, they block nothing,
and `dars.remove` succeeds afterwards. What remains is **history** in the event log, and with
`storage = memory` that grows monotonically until you restart.

Two mechanisms exist. Both work on a **database-backed** participant and neither on the
default in-memory sandbox.

**`repair.purge` — true deletion, verified working:**

| Storage | Result |
|---|---|
| in-memory (`dpm sandbox` default) | `CONTRACT_PURGE_ERROR(9,ca211163): synchronizer-1::…::35-0 is in memory which is not supported by repair. Use db persistence.` |
| **Postgres 16 (docker)** | **`REPAIR_PURGE => SUCCEEDED`  BEFORE activeContracts=2 → AFTER activeContracts=0** |

It also requires disconnecting first:
`CONTRACT_PURGE_ERROR(9,f339a187): There are still synchronizers connected. Please disconnect all synchronizers.`

Note this deletes **active** contracts outright — with it you would not archive at all.

**Pruning — deletes archived contracts and history. Not verified working.**
Blocked by the ledger deduplication window: `UNSAFE_TO_PRUNE: Participant cannot prune at
specified offset due to max deduplication duration of 168h`, and `find_safe_offset` returns
`None`. Setting `canton.participants.sandbox.init.ledger-api.max-deduplication-duration=60s`
is accepted and moved the error on to `UNSAFE_TO_PRUNE: no suitable offset for synchronizer
…`, but we never got a successful prune, on either storage backend.

Pruning is a documented, first-class Canton feature for storage management, so **asking why it
is unusable on a development participant is a legitimate question**, not a feature request.

---

## Contract keys ARE available (correction)

Keys are not missing in 3.5 — they are just off by default. The default compile target is
LF **2.2**, where `key` fails with *"Contract Keys not supported on current lf version (2.2),
feature supported in from 2.3"*. But damlc 3.5.2 also targets LF **2.3** and **2.dev**:

```yaml
build-options:
  - --target=2.3
```

With that, `key owner : Party` / `maintainer key` compiles, and Canton 3.5.12 **accepted and
vetted** the resulting package. Relevance: if B looks contracts up **by key** rather than
holding contract IDs, the reference survives a reload — you reseed A with the same keys and B
finds them again. Keys fix the *data* linkage; they do not avoid rebuilding the closure,
because that is a *code* linkage.

---

## Environment findings (worth reporting to Digital Asset separately)

1. **`dpm sandbox` cannot execute a single Daml transaction on an Oracle JDK.** Canton's fat
   jar bundles BouncyCastle unshaded and unsigned; Oracle JDKs enforce JCE provider signing,
   OpenJDK builds do not. Every submit fails with
   `SecurityException: JCE cannot authenticate the provider BC` →
   `JarException: … canton-open-source-3.5.12.jar is not signed`, surfacing to the client as an
   opaque `INTERNAL`. Upload, party allocation and topology all work, so the environment looks
   healthy until the first submit. Verified: Oracle 17.0.7 fails, Oracle 18.0.2 fails,
   OpenJDK 21.0.12.1 works.
2. **`dpm new --template empty-skeleton` omits `sdk-version`**, after which `dpm` exposes no
   subcommands at all — `dpm build` reports `unknown command "build" for "dpm"`.
3. **`dpm sandbox` on Postgres is not restart-safe.** Its startup bootstrap re-runs topology
   initialisation and fails against already-initialised databases
   (`TopologyAdministrationGroup$synchronizer_trust_certificates$.propose … Command execution failed`),
   killing the process. So the DB-backed route does not give you persistence across restarts.
4. **Postgres on macOS cannot host Canton.** Canton sets the Linux-only connection parameter
   `client_connection_check_interval`; Homebrew Postgres 14 rejects it
   (`invalid value for parameter "client_connection_check_interval": 5000`). A Linux container
   works.
5. **The sequencer needs two separate databases** — the node store and the reference-sequencer
   driver store. Sharing one makes Flyway fail: *"Detected applied migration not resolved
   locally: 1.1"*.
6. **`propose_delta` defaults to the Authorized store, which is a silent trap.** On a fresh
   participant that store holds no `VettedPackages` mapping, so a defaulted call computes its
   delta against an empty mapping, emits **serial 1**, can never supersede the synchronizer's
   serial, **changes nothing, and returns success.** Our first run was a false positive for
   exactly this reason. Always target `TopologyStoreId.Synchronizer(psid)`.
7. **Console ergonomics:** a bootstrap script that throws hangs the console unless stdin is
   redirected from `/dev/null`; and `import scala.util.{Try, …}` makes the console's Scala 2.13
   compiler read Scala 3 `scala/util/*.tasty` out of the fat jar and fail with *"Add
   -Ytasty-reader to scalac options"*. Fully-qualified `scala.util.Try` works.
8. **Two console feature gates, both console-side** (the sandbox itself needs no feature
   settings): `enable-repair-commands` for `repair.purge`, `enable-preview-commands` for
   `dars.remove`. `enable-testing-commands` does not unlock either.

## Timing

One reload: **~12s** — roughly 4s `dpm build`, 4s console session, 4s `dpm script` reseed.
Almost all of it is process startup: a no-op console session alone costs ~3s, so the upload
plus topology transaction is about 1s. A resident `dpm dev` holding one admin connection would
not pay that per save.
