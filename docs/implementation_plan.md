# Brim implementation plan

**Status:** authoritative build plan. Derived from Volume I (product research) and Volume II (architecture, agents, security). Those two documents are the specification; this one does not revisit their decisions.

**Audience:** an implementing agent or developer working task-by-task from an empty repository.

**Reading order:** §1 (invariants) and §2 (layout) before any code. §3 (frozen contracts) before any task in M1. §13 and §14 are authoritative wherever they conflict with the task catalogue — the catalogue is written first and then cut.

---

## Status, 4 October 2026

The supported cleanup and verification changes have completed their final review. Section 16 and the linked validation record define the current uninstall release scope and override the original milestone ambitions below. Universal erasure of every app-associated record is deferred, not unfinished work required for this release. The older milestone catalogue remains a development record; it is not a claim that all original acceptance criteria shipped.

The work since the last revision, beyond this plan (see also section 15): Developer finds project build folders and update downloads; the evidence search follows what it finds for up to three rounds and looks one level inside shared folders; Remnants (was Removed apps) uses Brim's own history as ownership evidence; the helper removes preference files in `/Library/Preferences`; matching builds an identity's lists once, which took Xcode's review from 13 seconds to 3.

The focused loading pass removes quadratic path comparisons, duplicate protection
reads and overlapping application enumeration. Footprint sizing is bounded to four
workers and volume results publish before leftovers estimates. The existing
registration preparation and aggregate accounting passes remain separate.
[Measurements and validation](performance.md) distinguish component timings from
real-app observations and list deferred work.

## 1. Invariants

These are checked at every task. A task that violates one is wrong even if it passes its own tests.

1. **`BrimCore` is pure.** No UI, no privilege, no network, no global mutable state, no hardcoded `/` or `~`. Every filesystem location resolves through an injected root. Violating this makes the whole system untestable.
2. **Nothing acts on a path handed to it.** Every mutation targets a step in a plan, and the component performing it re-derives its own authorisation.
3. **The pipeline has no bypass:** observe → plan → approve → apply → verify. There is no code path that mutates the filesystem outside it, including in tests (tests use the shadow root, not a side door).
4. **Approve is human-only.** No function, verb, tool, intent or model output can produce an approval token. The only producer is a user action in Brim's own window.
5. **Every adapter is thin.** The app contains presentation only. Zero logic. If an adapter needs a new behaviour, it goes in the service. Brim shipped a CLI and an MCP server once; both were removed to keep the product one thing.
6. **Everything crossing a process boundary is a value type.** Codable/NSSecureCoding, no references, no closures beyond reply handlers. This holds from day one even while the service runs in-process, or the XPC extraction in M2 becomes a rewrite.
7. **Filesystem-derived strings are untrusted.** Paths, display names, plist values and process names are data. They are never concatenated into a command, never executed, and are delimited and labelled wherever they reach a model.
8. **Trash, not unlink,** wherever the filesystem permits.
9. **The journal is written before the first mutation.** Always.
10. **Degrade, never fail.** Missing permission, unparseable format, absent helper — reduce capability and say so in the UI. Never a silent gap, never a crash.
11. **Density rule:** any list that can exceed ~1,000 rows is `NSTableView`-backed. Not a per-view judgement.
12. **Two-sided budgets.** Every performance claim names what Brim delivers and what it costs the machine.

---

## 2. Repository layout

One SPM package for everything that can be a library or a plain executable; one Xcode project for the three signed bundles.

```
brim/
├── Package.swift
├── Sources/
│   ├── BrimCore/            # pure. identity, model, evidence, safety, planning, verification
│   │   ├── FS/              # FileSystemRoot, DomainMap, path resolution
│   │   ├── Identity/
│   │   ├── Model/           # Artifact, Evidence, Tier, Capability, Plan, Step, Outcome
│   │   ├── Evidence/        # EvidenceSource protocol + concrete sources
│   │   ├── Safety/          # SafetyEngine, deny-lists, cost-of-error
│   │   ├── Planning/        # Planner, canonical encoding, content addressing
│   │   └── Verification/
│   ├── BrimScanShim/        # C shim: getattrlistbulk, openat family
│   ├── BrimScan/            # streaming enumerator over the shim
│   ├── BrimIndex/           # GRDB schema, migrations, writer actor, queries
│   ├── BrimOps/             # race-immune file operations. shared by executor AND helper
│   ├── BrimProtocol/        # service + helper wire types. value types only
│   ├── BrimService/         # service implementation. owns the index
│   ├── BrimHelperCore/      # helper logic. links BrimCore + BrimOps
├── Tests/
│   ├── BrimFixtures/        # fixture-tree generator + expected-evidence manifests
│   ├── BrimCoreTests/
│   ├── BrimIndexTests/
│   ├── BrimSecurityTests/   # the four vulnerability classes
│   └── BrimGoldenTests/     # evidence snapshots per macOS version
├── App/                     # Xcode project
│   ├── Brim/                # SwiftUI app
│   ├── BrimServiceXPC/      # XPC service bundle, Contents/XPCServices
│   └── BrimHelper/          # SMAppService daemon
├── docs/
│   ├── spikes/              # one findings file per spike
│   ├── plan-format.md
│   ├── security-model.md
│   └── uninstall-manifest.md
└── .github/workflows/
```

**Naming:** types are unprefixed inside their module (`Plan`, not `BrimPlan`). Modules carry the prefix.

**Language mode:** Swift 6, strict concurrency complete, warnings as errors in CI.

---

## 3. Frozen contracts

Write these before any feature work. Changing them later is expensive; changing them in M1 is cheap.

### 3.1 Step vocabulary

The complete set of things Brim can do. Adding a step kind is a deliberate act requiring a safety review; nothing else mutates anything.

| Step kind | Privilege | Reversible | Notes |
|---|---|---|---|
| `trashPath` | user | yes | default for everything removable |
| `trashPathPrivileged` | root | yes | system-domain items, via helper |
| `unloadLaunchdJob` | user or root | yes | by label, domain-scoped |
| `removeLaunchdPlist` | user or root | yes | always paired with unload |
| `resetPrivacyGrants` | user | no | `tccutil reset` scoped to one bundle id |
| `forgetReceipt` | root | no | `pkgutil --forget`, after files are handled |
| `clearImmutableFlag` | user or root | yes | explicit confirmation required |
| `delegateToolCleanup` | user | no | runs a named tool's own cleanup; exact command shown pre-approval |
| `revealVendorUninstaller` | none | n/a | opens Finder. Brim never runs it |
| `unregisterLaunchServices` | user | yes | `lsregister -u` on one bundle path, after the bundle is gone. Never `-kill -r` |

No `deleteRecursive`. No `runShellCommand`. No step takes a caller-supplied command string.

### 3.2 Plan format (`docs/plan-format.md`)

```jsonc
{
  "formatVersion": 1,
  "planId": "uuid",
  "createdAt": "iso8601",
  "engineVersion": "core-1.0.0+evidence-3",     // evidence engine revision
  "osVersion": "26.5.2",
  "intent": { "kind": "uninstall", "subject": "identity:bundle:com.example.App" },
  "requester": { "kind": "ui|intent", "identity": "signed-identity-string" },   // "app|cli|mcp|intent" until the CLI and MCP server were removed
  "steps": [
    {
      "index": 0,
      "kind": "trashPath",
      "target": "/Users/x/Library/Containers/com.example.App",
      "targetFingerprint": { "dev": 16777232, "ino": 1234567, "mtime": "iso8601" },
      "tier": "A",
      "evidence": "Sandbox container keyed to this bundle identifier",
      "expectedBytes": 419430400,
      "capability": "ok|needsHelper|needsFullDiskAccess|refusedByOS",
      "reversible": true,
      "costOfError": "Removes this app's saved documents and settings"
    }
  ],
  "excluded": [
    { "target": "...", "reason": "shared", "claimants": ["com.example.Other"] }
  ],
  "expectedTotalBytes": 1234567890
}
```

`planHash` = SHA-256 over the canonical JSON encoding (sorted keys, no whitespace, UTF-8). It is not stored inside the plan. It is the plan's identity and the binding used by approval tokens.

`targetFingerprint` is the anti-race binding: at execution time the opened descriptor's device and inode must match, or the step is refused.

### 3.3 Approval token

```swift
struct ApprovalToken: Codable, Sendable {
  let planHash: String          // binds to exactly one plan
  let requester: RequesterID    // binds to who asked
  let issuedAt: Date
  let expiresAt: Date           // minutes, not hours
  let nonce: UUID               // single use; consumed on first apply
}
```

Stored in the service's in-memory token store, consumed on use, never persisted, never transmitted outside the machine.

### 3.4 Service protocol

```swift
public protocol BrimServiceProtocol: Sendable {
  func inspect(_ q: InspectQuery) async throws -> InspectResult
  func plan(_ intent: PlanIntent) async throws -> Plan
  func explain(_ r: ExplainRequest) async throws -> Explanation
  func requestApproval(planHash: String, requester: RequesterID) async throws -> ApprovalRequestReceipt
  func apply(planHash: String, token: ApprovalToken) async throws -> ApplyOutcome
  func verify(planHash: String) async throws -> VerificationResult
  func history(_ q: HistoryQuery) async throws -> [LedgerEntry]
  func capabilities() async throws -> CapabilityReport
}
```

There is deliberately **no `approve`**. `requestApproval` raises Brim's window and returns a receipt; the token arrives back through the requester's own channel only after a human acts.

### 3.5 Helper protocol

As built, in `BrimPrivileged/HelperInterface.swift`. No call takes a path.

```swift
func removeDefunctJob(domain:name:withReply:)       // a launch job whose program is gone
func removeBrokenCommand(domain:name:withReply:)    // a command link that resolves nowhere
func forgetReceipt(packageID:withReply:)            // never Apple's
func removeInstalledBundle(domain:name:withReply:)  // a bundle an installer put down
func removeInstalledPayload(packageID:name:withReply:)
func removeSystemCache(name:withReply:)
func removeSystemPreference(name:withReply:)        // /Library/Preferences, files only
func recoveryItems(withReply:)              // Brim's fixed protected store
func removeRecoveryItem(identifier:expectedDevice:expectedInode:withReply:)
func version(withReply:)                     // "12"
func uninstallSelf(withReply:)
```

The temporary helper finds ordinary targets from their domain and name, proves they are in its supported scope, and refuses protected namespaces. Recovery removal is restricted to an existing copy in Brim's fixed store with its reviewed identity. Retiring the earlier registered helper preserves recovery copies; deleting them is a separate approved operation. `HelperScope` mirrors ordinary removal scope in the app. No arbitrary command or unrestricted deletion path is accepted.

---

## 4. Milestone 0 — Ground and spikes

**Goal:** be able to build, test and sign; know which architectural assumptions actually hold.

### T-0.1 · Package and project skeleton
- **Objective** A buildable workspace with the module boundaries of §2 enforced by the compiler.
- **Depends on** nothing.
- **Work** `Package.swift` with all library/executable targets and their dependency edges (note: `BrimCore` depends on nothing but Foundation; `BrimIndex` depends on GRDB and `BrimCore`; `BrimOps` depends on `BrimScanShim` only). Xcode project with three bundle targets. Swift 6 language mode, strict concurrency complete, warnings as errors.
- **Acceptance** `swift build && swift test` green. `xcodebuild` produces an app that launches to an empty window. A deliberate `import SwiftUI` inside `BrimCore` fails the build.
- **Unlocks** everything.

### T-0.2 · CI
- **Objective** No unverified commit reaches main.
- **Depends on** T-0.1.
- **Work** GitHub Actions on a macOS runner: build, test, strict-concurrency gate, SwiftFormat/SwiftLint. Pin the Xcode version explicitly. Cache SPM.
- **Acceptance** A PR with a concurrency warning is blocked.
- **Unlocks** safe iteration; T-0.3 onward.

### T-0.3 · Fixture tree generator
- **Objective** A synthetic machine that every test runs against, so correctness never depends on the developer's own Mac.
- **Depends on** T-0.1.
- **Work** `BrimFixtures` builds a deterministic tree under a temp root containing: a sandboxed app with a container and group container; a non-sandboxed app with Application Support, Preferences, ByHost preferences, caches, HTTPStorages, Saved Application State; a pkg-installed product with a receipt and BOM; launch agents and daemons in user and system domains; a CLI tool in `usr/local/bin`; **a vendor folder claimed by two installed apps** (the Tier S case); **a symlink pointing outside the tree** (the race case); an item with the immutable flag; an orphan whose owner is absent; an app present only on a second "volume". Ship an expected-evidence manifest per artifact.
- **Acceptance** Two generations produce byte-identical trees. The manifest round-trips.
- **Unlocks** all of M1; the golden tests; the shadow-root dry run.

### T-0.4 · `FileSystemRoot` and domain map
- **Objective** Core never knows where it really is.
- **Depends on** T-0.1.
- **Work** A `FileSystemRoot` value with a domain map (`.userLibrary`, `.systemLibrary`, `.applications`, `.receipts`, `.tempDirs`, …) resolving to absolute URLs. Real root and fixture root are the same type.
- **Acceptance** A test asserts `root.url(for: .userPreferences)` resolves under the fixture root, and that no string literal `"/Library"` exists in `BrimCore` (grep test).
- **Unlocks** every scanning and evidence task.

### Spikes

Each spike is timeboxed to two days, produces `docs/spikes/S-n.md` with the finding, and ends in a recorded go/no-go. A spike that fails does not block the milestone — it changes scope, and the fallback is written down.

| ID | Question | Pass criteria | Fallback if it fails |
|---|---|---|---|
| **S-1** | Is `getattrlistbulk` workable and fast for a full user-volume enumeration? | Attribute packing decoded correctly for size, dates, ids, link count, flags; ≥3× the throughput of `FileManager.enumerator` on the same tree; correct handling of symlinks and hardlinks | `fts(3)` via the shim; budgets loosen |
| **S-2** | Can an app, an XPC service and an `SMAppService` daemon mutually authenticate with `setCodeSigningRequirement` — **including during development**? | Working requirement strings for both Developer ID and local development; a modified client is rejected; a documented dev-mode that is impossible to ship | If dev signing is unworkable, a signed dev certificate becomes a prerequisite for all contributors — decide now, not in M2 |
| **S-3** | Can a root daemon with Full Disk Access actually remove a TCC-protected container, and does `trashItem` work from it? | Removal of `~/Library/Containers/<id>` succeeds; `EPERM` vs `EACCES` distinguishable; trashed items land somewhere restorable | Some removals become `refusedByOS` capability states and route to the vendor uninstaller. This is a **scope input**, not a failure |
| **S-4** | Is the app-in-a-table bridge viable? | `NSTableView` in `NSViewRepresentable` with 100k rows: selection, sorting, context menus, type-select, constant memory, 60fps scroll | Cap list sizes and paginate; revisit |
| **S-5** | Does a hardened-runtime, notarised build with the app + XPC service + daemon actually pass? | A notarised, stapled build installs and registers the daemon on a clean machine | Restructure bundles before any feature depends on the layout |

**Deferred spikes** (run immediately before the feature that needs them, not now): energy counters (before M5 energy), BTM parse (before M3 background items), APFS clone detection and snapshot accounting (before M5 storage).

**M0 done when:** CI is green, fixtures are deterministic, S-1 through S-5 have written findings, and any scope change from S-3 is recorded in this document.

---

## 5. Milestone 1 — The vertical slice

**Goal:** uninstall one application end-to-end, with the approval gate real and the result verified. No helper, no XPC transport, no privileged paths. Everything else in Brim is an extension of this spine.

### T-1.1 · Core model types
- **Objective** The vocabulary the whole system speaks.
- **Depends on** T-0.1.
- **Work** `Identity`, `ArtifactRef`, `ArtifactKind`, `Domain`, `EvidenceTier` (A/B/C/S), `Evidence` (tier + mechanism + human sentence), `Capability`, `CostOfError`, `StepKind` (§3.1), `Step`, `Plan`, `Outcome`, `LedgerEntry`. All `Sendable`, `Codable`, value types.
- **Acceptance** Round-trip encoding tests; canonical encoding is stable across runs and machine byte order.
- **Unlocks** everything in M1.

### T-1.2 · Identity layer
- **Objective** Resolve any application or artefact to a stable key. Nothing downstream matches on display names.
- **Depends on** T-1.1, T-0.4.
- **Work** Resolve from a bundle URL: bundle identifier, Team ID and code-directory hash via `SecStaticCode`, version, sandbox flag, declared group containers from entitlements, `SMAppService` items declared in the bundle. Resolve from a launchd plist: label and program path. Resolve from a receipt: package identifier. A single `IdentityResolver` with an injected root and a cache.
- **Acceptance** Against the fixture tree, every app resolves to the identity in the expected manifest, including the unsigned fixture app (degrades, does not throw).
- **Unlocks** evidence, footprint, index keys.

### T-1.3 · Filesystem enumerator
- **Objective** Walk a tree once, cheaply, without following links.
- **Depends on** T-0.4, S-1.
- **Work** `BrimScanShim` exposing `getattrlistbulk` with one attribute set. `BrimScan` providing an `AsyncSequence` of entries with cancellation, an exclusion list, bounded concurrency sized to performance cores, background QoS by default, and errors surfaced per-entry rather than aborting the walk.
- **Acceptance** Enumerates the fixture tree completely and identically across runs; does not traverse the symlink out of the tree; cancels within 100 ms; memory bounded on a synthetic 1M-entry tree.
- **Unlocks** index population, footprint sizing, leftovers, storage.

### T-1.4 · Index schema v1 and migrations
- **Objective** One durable store, versioned from the first commit.
- **Depends on** T-1.1, GRDB dependency.
- **Work** Tables: `identity`, `artifact`, `observation`, `evidence`, `plan`, `plan_step`, `ledger`, `journal`, `meta`. `DatabaseMigrator` with migration v1. WAL mode, connection pool. **History is stored as append-only observations, not derived aggregates** (Vol II §7).
- **Acceptance** Migrating an empty database and a v1 database both succeed; a deliberately corrupt database is detected and rebuilt rather than crashing.
- **Unlocks** all persistence.

### T-1.5 · Index actor
- **Objective** One writer, many readers, no data races.
- **Depends on** T-1.4.
- **Work** An actor owning the write connection; read queries through the pool; `ValueObservation` publishers for the UI. Batch insert path for scan results.
- **Acceptance** Concurrent read load during a bulk write shows no lock errors; Swift 6 concurrency checks pass with no `@unchecked Sendable`.
- **Unlocks** the service.

### T-1.6 · Evidence source protocol and the first three sources
- **Objective** Evidence as a plugin surface so M3 adds sources without touching the engine.
- **Depends on** T-1.2, T-1.3, T-1.5.
- **Work** `protocol EvidenceSource { func evidence(for: Identity, in: FileSystemRoot) async -> [EvidenceEdge] }`. Implement: **sandbox container** (Tier A), **installer receipt + BOM** (Tier A, via `pkgutil`/`lsbom` parsing), **exact bundle-identifier path component** (Tier B). Each emits a human sentence naming its mechanism.
- **Acceptance** Golden test: for each fixture app, the emitted edge set and tiers match the expected manifest exactly.
- **Unlocks** the evidence engine.

### T-1.7 · Evidence engine
- **Objective** A deterministic, version-stamped function from identity to tiered artefacts.
- **Depends on** T-1.6.
- **Work** Aggregate sources, deduplicate by target, resolve conflicts by taking the strongest tier, sort deterministically, stamp with an engine revision. Pure — no I/O of its own beyond what sources did.
- **Acceptance** Same input, same output, byte-identical, twice. Engine revision changes when a source changes.
- **Unlocks** footprint, safety, plans.

### T-1.8 · Footprint projection
- **Objective** "Everything about this app" as a query, never a stored object.
- **Depends on** T-1.7.
- **Work** A function from identity to grouped artefacts with sizes, tiers and capability placeholders. Computed on demand, cached only within a request.
- **Acceptance** Deleting an artefact from the fixture tree and re-querying reflects it immediately with no invalidation call.
- **Unlocks** the app inspector, uninstall planning.

### T-1.9 · Safety engine v1
- **Objective** The only component that may decide what gets selected.
- **Depends on** T-1.7.
- **Work** Tier defaults (A and B selected, C shown unselected, S excluded — S arrives in M3 but the branch exists now). An absolute deny-list: anything outside the known domain map, anything under the system volume, anything matching a reserved-path set, the running app itself. Cost-of-error annotation per step. Refusal is a returned reason, never a thrown error.
- **Acceptance** A fabricated evidence edge pointing at `/System` is refused with a named reason; a Tier C edge is present but unselected; the engine never returns a selected step outside the domain map.
- **Unlocks** the planner.

### T-1.10 · Planner and canonical encoding
- **Objective** Produce the object everything else revolves around.
- **Depends on** T-1.9, T-1.1.
- **Work** `PlanIntent` → `Plan` per §3.2, including `targetFingerprint` capture, `expectedBytes` summation, excluded-item list, and canonical JSON encoding with the SHA-256 content hash. Persist to the plan store directory.
- **Acceptance** Encoding is byte-stable across runs and locales; the hash changes if any field changes; a plan round-trips through disk unchanged.
- **Unlocks** approval, execution, agents, history, tests.

### T-1.11 · Service, in-process implementation
- **Objective** The single API, behind which everything hides.
- **Depends on** T-1.10, T-1.5.
- **Work** Implement `BrimServiceProtocol` (§3.4) as an actor. Wire inspect/plan/explain/requestApproval/apply/verify/history/capabilities. **All parameters and returns are value types**, ready to cross a process boundary in M2. A `ServiceClient` abstraction with a direct implementation now and an XPC implementation later.
- **Acceptance** A test exercising the protocol only — no direct Core access — can drive a complete uninstall on the fixture tree.
- **Unlocks** the app; the M2 extraction.

### T-1.12 · Approval gate and token store
- **Objective** The boundary that makes agents safe, built before any agent exists.
- **Depends on** T-1.11.
- **Work** `requestApproval` records a pending request and signals the UI. Human approval in the app mints an `ApprovalToken` (§3.3). In-memory store, single use, consumed on apply, expiry enforced, requester bound. No API path produces a token.
- **Acceptance** Tests prove: apply without a token fails; with an expired token fails; with a token for a different plan hash fails; with a replayed token fails; with a token minted for a different requester fails. A grep test asserts no function in the codebase returns `ApprovalToken` except the UI-triggered mint.
- **Unlocks** everything that applies a plan. Nothing reaches the executor without passing through here.

### T-1.13 · Race-immune operations library
- **Objective** Build the safe primitives now, so no unsafe ones ever exist to be used.
- **Depends on** T-0.1, S-1.
- **Work** `BrimOps`: open a parent directory with `O_NOFOLLOW`, operate with the `*at` family relative to that descriptor, verify the descriptor's device and inode against the step's `targetFingerprint`, refuse on mismatch. `trashItem` wrapper. No recursive-delete-by-path function exists in the module's API surface.
- **Acceptance** The symlink-swap test from `BrimSecurityTests` (T-2.8's first case, written here) fails to redirect an operation. A grep test asserts `removeItem(atPath:)` appears nowhere outside `BrimOps`.
- **Unlocks** the executor and, unchanged, the helper.

### T-1.14 · Journal and executor
- **Objective** Apply a plan so that a crash mid-way is recoverable.
- **Depends on** T-1.13, T-1.12.
- **Work** Write the journal before the first mutation. Execute steps in order, recording per-step outcomes. **The app bundle is trashed last** so a partially blocked run can be retried. Continue past blocked steps and report a mixed result. On launch, reconcile any open journal and offer completion or rollback.
- **Acceptance** Killing the process mid-apply leaves a journal that the next launch reconciles correctly. A plan with one refused step reports `partial`, not `failure`, and leaves the bundle in place.
- **Unlocks** verification, history, undo.

### T-1.15 · Verifier
- **Objective** Tell the truth about what happened.
- **Depends on** T-1.14.
- **Work** Re-observe the plan's targets, measure free space before and after with `statfs`, reconcile against `expectedTotalBytes`, and produce a `VerificationResult` that can state a zero delta with a reason.
- **Acceptance** On the fixture tree the measured delta matches the expected within tolerance. A synthetic case where bytes are pinned produces "recovered 0 bytes" with the reason field populated rather than a success message.
- **Unlocks** the verification screen, the credibility of every number in the product.

### T-1.16 · Ledger, history and undo
- **Objective** The record, and the way back.
- **Depends on** T-1.14, T-1.15.
- **Work** Persist plan + outcomes + verification as a `LedgerEntry`. Undo restores from the Trash, **checking the trashed items still exist first** and reporting "no longer recoverable" rather than failing. Record requester identity on every entry.
- **Acceptance** Undo after emptying the Trash reports unrecoverable without throwing. History survives a relaunch.
- **Unlocks** the History destination; agent accountability.

### T-1.17 · Minimal app
- **Objective** A window that can drive the pipeline and approve.
- **Depends on** T-1.11, T-1.12.
- **Work** `NavigationSplitView`: sidebar with Applications and History only; content list of applications; inspector showing the footprint grouped by tier with the evidence sentence in each row; a plan document sheet; the approval control; the verification result; History list. Standard components only — the platform material comes free.
- **Acceptance** A human can uninstall a fixture app and read why every item was included.
- **Unlocks** approval. It is the only place in Brim one can be given.

### T-1.18 · CLI v1 · Dropped
Built, shipped outside the app bundle, and removed. It was the only part of
Brim that registered a launch agent, which a utility whose whole subject is
software running when nobody asked it to should not do. What it was for,
proving the gate holds for a client with no window, is now held by
`ApprovalGateTests` directly, which is a better place for it than a second
executable.

### T-1.19 · Shadow-root dry run
- **Objective** Run the entire pipeline against a copy, for tests and for a user-facing preview.
- **Depends on** T-1.14.
- **Work** A mode where `FileSystemRoot` points at a copied tree and all mutations apply there. Wired end-to-end, including verification.
- **Acceptance** A full uninstall in dry-run mode changes nothing outside the shadow root, and produces a `VerificationResult` comparable to the real one.
- **Unlocks** safe development; regression tests that execute rather than simulate.

**M1 done when:** on both the fixture tree and a real machine with a disposable app, an uninstall completes from the app; a service with no window cannot act at all; the plan is readable before it runs; the verification reports a measured delta; undo works; History records the run with the correct requester. **No privileged paths, no helper, no XPC yet.**

---

## 6. Milestone 2 — The trust boundary

**Goal:** make the process topology and the privilege boundary real, with the security properties tested rather than intended. Nothing user-visible is added.

### T-2.1 · Service in process, XPC kept ready · changed
- **As built** `BrimService` runs inside the app. The XPC client, server and `MutualAuthentication` exist and are tested (`XPCAuthenticationTests`), but no XPC service bundle is built. Root work goes through the small helper in T-2.3 instead, which is the only thing that needs another process.
- **Why** One index owner is still true in process, and an out-of-process service bought nothing the helper does not already give, at the cost of a second signed bundle to ship.
- **Still true** Approval is minted only in the app's own process (§3.3), and `ApprovalGateTests` holds it.

### T-2.2 · Mutual code-signing requirements
- **Objective** Only Brim's own signed components can reach the service or the helper.
- **Depends on** T-2.1, S-2.
- **Work** `setCodeSigningRequirement` applied on both directions, **before the interface is exported**, never after. Separate requirement strings for release and development builds, with the development path impossible to enable in a Developer ID build. Never use the process identifier.
- **Acceptance** A test client signed with a different identity is rejected. A grep test asserts `processIdentifier` is never read for an authorisation decision.
- **Unlocks** the helper.

### T-2.3 · Privileged helper · done, narrower than planned
- **As built** `BrimJobHelper` is a signed temporary administrator process, not a persistent `SMAppService` daemon. It independently checks supported targets and requesting-user identity. A selected protected batch shares authentication through execution and verification, then closes the process. Disconnect shutdown is bounded. Earlier registered-helper migration preserves recovery copies. Current interface version 12; see section 16 and the validation record for scope and checks.
- **Acceptance** A plan never offers a root-owned item the helper will refuse; `HelperScopeAgreementTests` holds the two readings to one answer; an unsigned client is refused.

### T-2.4 · Independent re-validation in the helper
- **Objective** A compromised app still cannot cause a bad deletion.
- **Depends on** T-2.3.
- **Work** Before executing any step, the helper links `BrimCore` and re-runs the evidence and safety checks for that step's target, from its own observation. Mismatch with the plan's stated tier is a refusal, recorded.
- **Acceptance** A test injects a plan whose step claims Tier A for a target that the evidence engine rates Tier C; the helper refuses. A test where the target is swapped between planning and execution is refused on the fingerprint check.
- **Unlocks** the security claim that the product is sold on.

### T-2.5 · Capability pre-checks
- **Objective** Know what macOS will refuse before asking.
- **Depends on** T-2.3.
- **Work** At plan time, classify each step: `ok`, `needsHelper`, `needsFullDiskAccess`, `refusedByOS`. Distinguish `EPERM` (privacy) from `EACCES` (POSIX) when probing. Surface the classification in the plan and in the UI row.
- **Acceptance** On a machine without Full Disk Access, container steps are classified `needsFullDiskAccess` at plan time and the plan is still produced and readable.
- **Unlocks** the permission ladder; vendor-uninstaller routing in M3.

### T-2.6 · Permission ladder
- **Objective** Useful with zero grants; asks only at the moment of impact.
- **Depends on** T-2.5.
- **Work** No onboarding wall. Each capability requested when it would change a result, phrased as consequence. Blocked locations shown as findings, not gaps.
- **Acceptance** First launch with no permissions shows real findings and names exactly what it cannot see.
- **Unlocks** the first-run experience.

### T-2.7 · Security regression suite
- **Objective** The four documented vulnerability classes become permanent tests.
- **Depends on** T-2.4.
- **Work** In `BrimSecurityTests`: (a) an unauthorised client attempting to drive the service and the helper; (b) caller impersonation with a mismatched signature; (c) a symlink swapped between plan and execution; (d) a directory replaced by a symlink mid-traversal during a recursive operation. Plus a malformed-message fuzz pass over the XPC interfaces.
- **Acceptance** All four fail to achieve their objective and all four are recorded as refusals with reasons. The suite runs in CI on every PR.
- **Unlocks** shipping with root access in good conscience.

### T-2.8 · Self-verification
- **Objective** Brim notices if it has been tampered with.
- **Depends on** T-2.3.
- **Work** On launch, verify the app's own signature and the helper's signature and version. A mismatched helper is not used; the user is offered reinstallation.
- **Acceptance** A helper binary replaced with a different signed build is refused.
- **Unlocks** T-6.7 self-policing.

### T-2.9 · Signing and release · changed
- **As built** `scripts/build_release.sh` archives, signs with the first Developer ID or Apple Development certificate in the keychain, verifies the signature and both requirements, builds a disk image and writes its checksum. It notarises only when `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` and `APPLE_TEAM_ID` are set.
- **Decision** 1.0 ships signed with the free Apple Development certificate and not notarised. People open it once through Privacy & Security, Open Anyway. Brim's requirements accept that certificate, and Full Disk Access survives updates because the signature is stable.
- **Open** `release.yml` builds on a runner that may lack the macOS 27 SDK and has no signing identity. 1.0 is built locally.

**M2 done when (as revised):** both ends of every connection authenticate by signature, the helper exists with the §3.5 vocabulary and proves each item itself, the security tests pass, and a signed release builds locally. The out-of-process service and a notarised CI build were set aside; see T-2.1 and T-2.9.

---

## 7. Milestone 3 — Evidence at full strength

**Goal:** the evidence model reaches the coverage Volume I specified, including the shared-file veto and the background-items surface. Each source is an independent task and they parallelise cleanly.

### T-3.1 · Remaining Tier A and B sources
- **Objective** Full coverage of the mechanisms macOS actually provides.
- **Depends on** T-1.6.
- **Work** Group containers resolved from entitlements; `HTTPStorages`, `Saved Application State`, `Application Scripts` keyed by bundle identifier; Launch Services registration; Team-ID-signed property lists and binaries; `SMAppService` items declared inside a bundle. One source per file, all conforming to the existing protocol.
- **Acceptance** Golden manifests extended; each source individually unit-tested against its fixture case.
- **Unlocks** complete footprints.

### T-3.2 · launchd inventory
- **Objective** Know every job, in every domain, and whose it is.
- **Depends on** T-1.2, T-2.3.
- **Work** Enumerate `LaunchAgents` and `LaunchDaemons` in user, local and system domains. Parse labels and program paths; resolve program paths back to a bundle identity where possible. Pair `unloadLaunchdJob` and `removeLaunchdPlist` steps so a plist is never removed while loaded.
- **Acceptance** A fixture daemon is correctly attributed to its owning app; an orphaned plist whose program is gone is flagged.
- **Unlocks** background items; the leftover class Volume I identified as actually harmful.

### T-3.3 · Background Task Management ingestion
- **Objective** See what System Settings hides.
- **As built** Read the current Background Task Management archive with Full Disk Access, without invoking `sfltool dumpbtm` or requesting administrator access for ordinary scans. Attribute application records and retain ambiguous targets and read gaps. A missing target is not evidence that macOS will remove its record.
- **Acceptance** With parsing deliberately disabled, the background view still renders and targeted removal still works. A synthetic malformed dump produces a degraded view, not an error dialog.
- **Unlocks** background registration inspection and removal verification. No guided global reset ships.

### T-3.4 · Tier S shared-file veto
- **Objective** The control that prevents the category's signature failure.
- **Depends on** T-3.1.
- **Work** Detect targets claimed by two or more installed identities, referenced by another product's receipt, or inside a group container shared with a present app. **One-way only:** Tier S can move an item out of the default selection, never into it. Record the other claimant by name.
- **Acceptance** The fixture's two-app vendor folder is excluded from both apps' plans with the other claimant named. A test asserts no code path allows Tier S to select anything.
- **Unlocks** safe uninstall of suite software.

### T-3.5 · Tier C correlated sources
- **Objective** Find more, select none of it.
- **Depends on** T-3.4.
- **Work** Vendor-name folders, product-name similarity, install-time clustering. Emitted as Tier C with an honest sentence ("name resembles the vendor").
- **Acceptance** Tier C items appear in plans as `excludedFromSelection`, are individually selectable in the UI, and cannot be bulk-selected by any control.
- **Unlocks** the "41 confirmed, 7 your call" framing.

### T-3.6 · Privacy grants
- **Objective** Treat permissions as part of the footprint.
- **Depends on** T-2.6.
- **Work** Read the grants an identity holds (requires Full Disk Access; degrade otherwise). Offer `resetPrivacyGrants` as a step on uninstall. Show grants in the inspector.
- **Acceptance** An uninstall plan for an app holding grants includes the reset step, marked irreversible.
- **Unlocks** a footprint element no competitor shows.

### T-3.7 · Vendor uninstaller routing and locked items
- **Objective** Convert the dangerous cases into safe ones.
- **Depends on** T-2.5.
- **Work** Detect a bundled uninstaller, a receipt-declared uninstall script, or a known vendor tool. Emit `revealVendorUninstaller` and mark the app's own plan as incomplete-by-design with an explanation. Detect the immutable flag and offer `clearImmutableFlag` with explicit confirmation.
- **Acceptance** For a fixture app with a bundled uninstaller, Brim proposes revealing it rather than guessing. The immutable fixture item is detected and not silently skipped.
- **Unlocks** correct handling of the suites that historically break.

### T-3.8 · Background and login items surface
- **Objective** The clearest gap in the platform, made usable.
- **Depends on** T-3.2, T-3.3.
- **Work** A view listing every item with its owner, path, signing state and whether the owner still exists. Targeted removal where a backing file exists (unload then remove).
- **Acceptance** A job pointing at a program that has gone can be removed; one pointing at something real cannot be removed by accident.
- **Unlocks** a headline feature.
- **Dropped** the guided `btmReset` flow because it changes the machine-wide store rather than selectively removing an app's records. Automatic collection is not a supported completion guarantee. Remaining records are shown with qualified manual guidance; no global reset is part of uninstall.

### T-3.9 · Evidence golden tests per OS version
- **Objective** Notice when Apple changes the ground.
- **Depends on** T-3.1.
- **Work** Snapshot the evidence output for the fixture corpus, stamped with engine revision and OS version. CI runs against the supported OS matrix; a diff is a reviewable failure, not a silent change.
- **Acceptance** Changing a source without updating snapshots fails CI with a readable diff.
- **Unlocks** surviving each September.

**M3 done when:** a full uninstall plan for a real, complex application (a suite, a security tool, a pkg-installed product) is correct, the shared veto is demonstrably protecting sibling apps, and the background-items view shows more than System Settings does.

---

## 8. Milestone 4 — Agent surfaces

**Goal:** one read-only agent surface over the API, and the tests that prove
no surface can approve anything. Two of the three adapters this milestone was
written for have since been removed; the gate they were designed around is
what remains, and it is the part that mattered.

### T-4.1 to T-4.4 · Dropped
Brim shipped an MCP server and a command line tool. Both were removed, along
with the requester-labelling and untrusted-string work that existed to make
them safe. Neither was broken; neither was the product. The approval gate
that was designed around them stays exactly as it is, because the rule it
enforces, that nothing outside Brim's own process has a method that mints
approval, is what makes the app safe to give root to, adapters or not.

### T-4.5 · App Intents
- **Objective** Apple's own agent surface, safely.
- **Depends on** T-2.1.
- **Work** Read-only intents (storage summary, background-item count, app footprint, update status) plus one intent that opens a plan for review. Entities for applications and plans. Nothing destructive reachable from an unattended automation.
- **Acceptance** A Shortcuts automation running with nobody present can report, and cannot remove anything.
- **Unlocks** Spotlight and Shortcuts reach.

### T-4.6 · Agent safety test suite
- **Objective** The capability table, enforced by tests rather than by intent.
- **Depends on** T-1.12, T-4.5.
- **Work** Tests for: approval attempted from a service with no consent source; token replay, expiry, wrong plan, wrong requester; a plan mutated after approval; an injected filename attempting to steer a tool result; a model-shaped input naming an out-of-plan target.
- **Acceptance** All fail closed, with reasons recorded in the journal.
- **Unlocks** the strongest differentiator in the product.

**M4 done when:** App Intents can report and cannot remove, no service without a window can mint a token, and every bypass attempt in T-4.6 fails.

---

## 9. Milestone 5 — Feature expansion

Every task here is an extension of the spine. They parallelise almost completely; the ordering below is by value, not by dependency.

### T-5.1 · Remnants (was Leftovers, then Removed apps) · done
- **As built** The page is Remnants. One card per app that has gone and left something, with its saved icon, when Brim saw it go, the places it left folded inside the card, and Finish Removal, which opens a review. Brim's snapshots are ownership evidence: an app Brim saw installed and now cannot find owns what it left. Items nobody can be named for go into a collapsed "Unknown" list of plain rows, only from 1 MB, never counted and never ticked. Home dot folders and crash reports are listed only when a removed app from Brim's history is named for them, never as unknown. Folders written in the last week, folders holding a `com.apple` file of their own, paths Developer claims and folders named for an installed command are not listed.
- **Acceptance** Orphaned and unclaimed are never merged; unclaimed items never reach a figure; macOS's own folders are not offered.

### T-5.2 · Reset and archive · removed
- **Removed 30 September 2026.** Both reached the plan types, the planner and the executor, and Reset had a button in the app inspector, but neither was ever run end to end on a real app, and neither is removal or proof. The step kind `archivePath`, the `archive` execution phase, the `reset` and `archive` intents, `ResetFilter` and their tests are gone. Plans stored before this still decode; the extra fields are ignored.

### T-5.3 · Storage account
- **Objective** The three numbers, always together.
- **Depends on** T-1.3, deferred spike on snapshot accounting.
- **Work** Logical size from enumeration; reclaimable from the evidence model; snapshot-pinned and purgeable from volume and snapshot enumeration. Never collapse them into one figure.
- **Acceptance** On a machine with local snapshots, the pinned figure is non-zero and the reclaimable figure excludes it. A deletion that frees nothing is explained rather than reported as success.
- **Unlocks** the category's most credible feature.

### T-5.4 · Duplicates · Dropped
Built and removed. A byte-for-byte file finder has nothing to do with what
software leaves behind, it asked the person to pick a folder when nothing else
in the app does, and `strategy.md` listed duplicates under "Deliberately not
doing" the entire time it shipped. The clone-detection spike it depended on is
dropped with it.

### T-5.5 · Energy sampler
- **Objective** Real joules, accumulated.
- **Depends on** T-2.3, deferred spike on energy counters.
- **Work** Sample `proc_pid_rusage` with `RUSAGE_INFO_V6` **when the panel is open and not otherwise**. Aggregate by coalition where available and by bundle path otherwise. Root-owned processes read through the helper when available, marked as a coverage gap otherwise.
- **Acceptance** Coverage gaps are displayed, not hidden. Closing Brim leaves nothing running.
- **Amended.** This task specified an opt-in persistent agent registered via `SMAppService` that accumulated energy across restarts, and a ledger was built for it. Nothing ever read the ledger back, and a utility whose subject is software running when nobody asked it to should not register an agent to watch a battery. The ledger, the insight model and the battery projection are removed; `EnergySampler` reads what is true now, on demand.
- **Unlocks** the sentence no competitor can produce.

### T-5.6 · Energy view
- **Objective** Make the number actionable.
- **Depends on** T-5.5.
- **Work** Per app, in mWh and as a share of the battery's design capacity, over a chosen period. Power assertions and high-performance graphics use shown beside the figure. **No predicted battery life, in minutes or otherwise.** The rate arithmetic is shown, not hidden.
- **Acceptance** A grep test asserts no string in the product projects future battery life in time units.
- **Unlocks** the differentiator, on the terms Volume I set.

### T-5.7 · Developer cleanup
- **Objective** High yield, correctly classified.
- **Depends on** T-1.10.
- **Work** Three classes: regenerable caches deleted directly; tool-managed stores delegated with the exact command shown before approval; stateful artefacts reported and routed, never touched. Container disk images and simulator devices are always class three.
- **Acceptance** A test asserts no code path deletes a container runtime disk image or an Xcode archive.
- **Unlocks** the developer audience.

### T-5.8 · Updates · done, beyond the original scope
- **As built** Sources, first party first: the App Store receipt (the Mac listing, not a shared iPhone one), the app's Sparkle feed, its electron-builder feed, then Homebrew's catalog, falling through when one fails. Brim installs updates itself: it downloads with resume and retries, checks the hash or EdDSA signature, and checks that the new bundle has the same identifier and developer, is newer, runs on this Mac and passes Gatekeeper. It then swaps it in with one atomic exchange, recoverable after a crash, and sends the old copy to the Trash. App Store updates open the store, packages open Installer, Homebrew installs go through `brew`. A refusal by macOS is its own state with a button to App Management.
- **Checks** When the page opens and the last check is over six hours old, and on Check Again. Never in the background.
- **Screen** Available, Updated recently (last two weeks, from receipts and snapshots), All apps are up to date, Failed with Retry, and a count of apps that cannot be checked.

### T-5.9 · Migration hygiene and footprint history
- **Objective** What came across and never ran here.
- **Depends on** T-1.16, T-3.1.
- **Work** Compare install dates against the system install date and first-launch records. Differential snapshots of the install surface between sessions, so newly appeared footprints are derivable by subtraction without any watcher.
- **Acceptance** A fixture app predating the fixture "system install" is flagged. No resident process is introduced.
- **Unlocks** growth findings and the review queue's most useful signal.

---

## 10. Milestone 6 — Product and release

### T-6.1 · Table bridge productionised
- **Objective** The density rule, implemented once.
- **Depends on** S-4.
- **Work** A reusable `NSTableView`-backed SwiftUI view with selection, sorting, type-select, context menus and column persistence. Every list over ~1,000 rows uses it.
- **Acceptance** 100k rows: constant memory, 60fps scroll, full keyboard traversal.

### T-6.2 · Home · changed
- **As built** Home rather than a ranked queue: what changed since the last look, what needs the person, and a card per page with its figure. No score, no percentage, no health colour.

### T-6.3 · Explanations
- **Objective** Deterministic prose from the evidence model.
- **Depends on** T-1.7.
- **Work** A renderer producing the human sentence for every tier, capability and refusal. No template reads like a log line.
- **Acceptance** Every row in every plan has a sentence; a missing one fails a test.

### T-6.4 · Accessibility and keyboard
- **Objective** Complete, not retrofitted.
- **Depends on** T-6.1.
- **Work** Tier never encoded by colour alone; spoken labels read the evidence, not just the filename; Reduce Transparency, Increase Contrast and Reduce Motion honoured; full keyboard traversal with a menu command for every action.
- **Acceptance** The full uninstall flow is completable with VoiceOver and without a mouse.

### T-6.5 · Performance budgets and instrumentation
- **Objective** Two-sided, measured, published.
- **Depends on** T-1.3, T-5.5.
- **Work** Signposts through the scan and apply paths. Background QoS by default; thermal-state and low-power back-off; `beginActivity` around long work. A CI performance test with recorded baselines.
- **Acceptance** First index under a minute at background priority on the reference machine; incremental refresh under two seconds; bounded steady-state memory; and **Brim's own line visible in Brim's own energy view**.

### T-6.6 · Self-policing and self-removal
- **Objective** Prove the product's central claim on the product itself.
- **Depends on** T-2.8, T-5.5.
- **Work** Brim lists its own records on the same terms as other apps. Self-removal handles supported owned files and services, then reports confirmed absence, retained recovery copies, remaining registrations and unavailable checks.
- **Acceptance** Self-removal must not label retained or unverified records removed. Universal erasure of every macOS-owned record is outside the current release scope.

### T-6.7 · Release engineering · changed
- **As built** No Sparkle. Brim asks GitHub for its latest release when it opens, at most once a day, and on Check for Brim Updates, and shows a notice in the sidebar that opens the release page. It never replaces itself. A 404 before the first release means nothing newer.
- **Open** Homebrew cask, published code-directory hash, release notes.

### T-6.8 · Open-source split and documentation
- **Objective** The safety claim must be auditable.
- **Depends on** M3.
- **Work** Publish `BrimCore`, `BrimOps` and the evidence sources under a permissive licence. Publish `docs/plan-format.md`, `docs/security-model.md` and `docs/uninstall-manifest.md`. Ship Brim's own uninstall manifest in its bundle.
- **Acceptance** A third party can build and run the evidence engine against the fixture corpus from the public repository alone.

---

## 11. Milestone 7 — Complete removal, and what it lets Brim say

Added after M6 was largely built, when a measurement of six real applications showed the removal path missing between four and seven locations each. The full research and the reasoning behind every decision here is `docs/leftover-coverage-and-intelligence-plan.md`; this section is the task catalogue.

**The premise.** Deep uninstall is the product. Leftovers is the same search run backwards, not a separate system, and the two disagreeing is the defect class that produced `7b52119`, `ae25162` and `bdb407d` in a single day. M7 makes removal complete first and derives everything else from it.

### 11.1 The ownership boundary, which governs every task below

> **Brim removes the application's own records. It never removes a document that outlives the application.**

Personalisation is not protection. Bookmarks, preferences, window layouts and sign-in state were all given to the application by the person using it, and every one of them leaves with the application. The discriminator is whether the thing still means anything once the application is gone. Two mechanical tests: a path is in scope only if `LocationInventory` names it with a rule, and a subtree inside application storage that the bundle declares as document scope (`CFBundleDocumentTypes` with an `Editor` role and `LSHandlerRank: Owner`, or `NSUbiquitousContainerIsDocumentScopePublic`, or a container's `Data/Documents`) is archived rather than trashed. A reference to user content is a third class: the record goes, what it names does not.

### T-7.1 · The measured misses (was P1.1 to P1.7) · **done**
- **Objective** Recover what the removal path provably leaves behind today.
- **Depends on** nothing. Deliberately first, because T-7.2 is weeks and this is days.
- **Work** `CFBundleName` in `LocationInventorySource.candidates`, with a test holding `LeftoversScanner` and `LocationInventorySource` to one answer for one bundle. `~/.config`, `~/.cache`, `~/.local/{bin,share,state}` and vendor dotfile directories, name-matched, Tier C. `bundleIdentifierPrefix` in caches and application support, which catches `<id>.ShipIt`. Launch Services recent-documents `.sfl4`, with §11.1's guard landed as a test first. Team identifier resolution in `IdentityResolver`. Symlinks pointing into an installed bundle.
- **Acceptance** The same six applications re-measured, with the before and after written down. VS Code's 143 MB and Claude's 189 MB are in the footprint. A test fails if any scanner resolves a path recorded in a `.sfl4` into a scan target.
- **Unlocks** the two largest numbers on the board, in days.

**Measured, same Mac, same six applications.** `FootprintCoverageTests`
behind `BRIM_REAL_ENV=1` is the harness, and every assertion in it failed
before this work.

| Application | Before | After |
|---|---|---|
| Visual Studio Code | 6 | 15 |
| Claude | 7 | 14 |
| Antigravity | 7 | 12 |
| Figma | 5 | 6 |
| Obsidian | 4 | 5 |
| Recordly | 6 | 7 |

Visual Studio Code's 143 MB in `Application Support/Code` and Claude's
189 MB in `~/.local/share/claude` are both in the footprint. Team
identifiers resolve for six of six where they resolved for none.

Three things came out of doing it that the plan had not anticipated.

- **`IdentityResolver` was asking macOS the wrong question.**
  `SecCodeCopySigningInformation` was passed `kSecCSRequirementInformation`
  alone, which carries the entitlements but not the team identifier, so
  `teamID` was nil for every application ever scanned and `TeamIDSource`
  had never run. `CodeSignature` in `BrimScan` had it right, which is the
  two-readings hazard again.
- **Fixing that exposed a live over-claim.** `TeamIDSource` rated every
  `TEAMID.*` group container Tier B. A team identifier names a vendor, so
  uninstalling Visual Studio Code offered to delete Microsoft Teams' data
  and the shared Microsoft sign-in state, pre-selected, with Teams
  installed. A team-prefix match is now Tier S when a sibling is installed
  and Tier C otherwise, and never Tier B.
- **A name match is Tier B in one source, knowingly.**
  `BundleIdentifierComponentSource` rates a folder named after the
  application's file name Tier B, against the inventory's rule that a
  name match is C. It was demoted to C and put back: the uninstall sheet
  lists only what is ticked, so a Tier C row there cannot be ticked by hand
  at all, and uninstalling Claude would have stopped removing its 11 GB
  `Application Support/Claude`. The new `CFBundleName` match, which can be
  as short as "Code", is Tier C as the plan requires. The file-name match
  can follow the rule once the sheet can offer an unticked row, which is
  Part 4a's grouped sheet, and that dependency should be recorded against
  P3.5.
- **The same team fix reached launchd.** `LaunchdSource` claimed any job
  whose label starts with the team identifier at Tier A, which is unloaded
  by default. It is Tier S or C now, on the same terms as a group
  container.
- **The footprint view's headings lied once sources disagreed.** Groups were
  keyed on the source, headed by the first row's sentence and labelled with
  the strongest row's tier. A group is now the rows that share a sentence
  and a tier, so both are true of every row.

Deferred deliberately, both recorded in `notWorthSweeping` with reasons:
the `.sfl4` directory and the XDG folders are searched on the uninstall
path but held out of the leftovers sweep, the first until Apple's own
records can be told apart and the second until the sweep can recognise a
command line tool as still installed.

### T-7.5 prerequisite · Offer unticked rows in the uninstall sheet · merged in PR #1

Moved ahead of T-7.2 from the sheet work in T-7.5. The uninstall review now
offers discovered, unticked rows with their path, size and a short label.
Detailed evidence is available through Details. A manual selection travels
on `PlanIntent.tickedByHand`, so approval covers it and apply reconstructs
it. Each toggle builds a fresh plan; approval is disabled until it arrives,
and stale replies cannot replace the current selection. Vetoed rows cannot
be selected, and naming a path the footprint never found adds nothing.

Verified on 26 September 2026: planner, service fixture flow, approval gate,
Tier S and model timing tests pass; the full plain suite and Debug app build
pass. In the running app, VS Code's `Application Support/Code` is offered
at 166 MB, inclusion changes the plan, and unticking returns the row to the
optional list and updates the totals. No installed application was removed.
The shell could not enumerate `~/.Trash`, so the Trash baseline is unverified.

The review's scroll lag was traced to repeated window layout and SwiftUI
size negotiation. The sheet now uses a fixed 660 by 520 point presentation
instead of minimum and ideal content dimensions. In 20-second main-thread
samples containing the same ten-scroll sequence, inclusive window-layout
samples fell from 1,206 to 136 and transaction-flush samples from 1,241 to 5.
These are sampling observations, not frame-rate measurements. Neither
capture included planner calls. The Details control and compact rows were
checked in the running app after the change.

The file-name source's Tier B exception is addressed in T-7.2 below.
Grouping and the rest of T-7.5 remain in their original position. M7 is not complete.

### T-7.2 · Capability-derived search (was P2.1 to P2.3)
- **Objective** Replace category reasoning with the application's own declarations.
- **Depends on** T-7.1, T-1.2, T-3.1, and the unticked-row sheet prerequisite above.
- **Work** `IdentitySurface`: every name a bundle answers to, from `Info.plist`, the signature, and embedded helpers, XPC services and app extensions. `CapabilitySurface`: entitlements and declarations mapped to the record classes that can exist, so `NEProviderClasses` implies a network extension and `com.apple.security.device.camera` implies one TCC entry. Planning consumes both. Unsigned and ad-hoc bundles thin the capability surface to `Info.plist` alone and that is a `RegistrationCoverage` gap, reported as one.
- **Acceptance** An uninstall reports what it checked *and* what the application declared it had none of, and the two are distinguishable in the report. No app names appear in the implementation. A name-derived match is Tier C whatever produced the name.
- **Unlocks** negative evidence, which is the only honest way to say a surface is clean.

**Implementation in PR #2:** the evidence protocol carries complete, unreadable
and timed-out searches through the safety engine, plan and review. Directory
reads distinguish missing locations from failures. Name matches are Tier C.
The bundle reader collects identifiers, names, groups, URL schemes, exported
types, helper requirements and extension declarations from the app and its
packaged components. It uses signed entitlements only when the signature is
valid and not ad hoc. A signature gap is reported separately from declarations
read from Info.plist. Embedded identifiers expand the search but remain Tier C
without direct ownership evidence. Declared groups expand the group-container
and Application Scripts search. Declared job labels expand the launchd search.
The review has a compact search-details panel. It shows declaration and read
status separately, including record counts and read limitations. The report is
part of the plan hash and is reconstructed before apply. Unreadable locations
leave the automatic selection empty; a Tier S veto cannot be overridden.
Privacy grants and another app's VPN settings are marked unavailable because
Brim cannot enumerate them through a supported reader. No declaration is
treated as proof that either record class is empty.

**Validated:** the package suite, approval tests, Debug build and lint
comparison passed. In the running app, Figma's 1.21 GB support folder was
offered unticked. Search details showed checked, undeclared and unavailable
record classes separately. The review was cancelled without removal. T-7.2
is complete; M7 still depends on later tasks.

### T-7.3 · The removal ceiling, reported rather than hidden (was P2.4, P2.5)
- **Objective** Say what macOS will not allow, once, in the right place.
- **Depends on** T-7.2, T-3.3.
- **Work** Distinguish supported removal from records Brim can only observe or route to their owner or Settings. A machine-wide reset is not a selective uninstall operation and is not offered. Missing-target Background Task Management records can remain; collection is never assumed to complete removal.
- **Acceptance** A tier-3 outcome names the one action that does work rather than describing what Brim cannot do.
- **Unlocks** an honest completion claim, and closes the last dead step kind.

**Implementation:** `RemovalTier` classifies targeted removal, the system-wide
BTM reset that Brim does not offer, and records needing another action. Search
details show the tier and a short action for declared VPN settings, observed
system extensions and privacy access that may outlive a missing bundle. The
completion report rechecks previously observed system extensions. It gives a
conditional VPN action because macOS does not expose another app's VPN
configuration to Brim. A failed or missing privacy-reset outcome prevents a
successful verification claim; if the bundle is gone, the report says to
reinstall it before resetting permissions. No system-wide BTM reset is run.

**Validated:** the package suite, approval tests, Debug build and lint
comparison passed. Fixture verification reports failed privacy resets without
claiming a completed uninstall. The running app's search-details text was not
visually checked because the automation window stopped accepting interaction;
no application was removed. T-7.3 is complete; M7 still depends on T-7.4
through T-7.6.

### T-7.4 · Leftovers re-derived from the removal engine (was P2.6)
- **Objective** One engine, two directions.
- **Depends on** T-7.2.
- **Work** An orphan search is the identity surface and the location rules run from the record towards the owner instead of from the owner towards the record. Shared tier model, shared rules, one implementation.
- **Acceptance** A test binds the two directions: for one bundle, what the uninstall would remove and what the sweep attributes to it are the same set.
- **Unlocks** the end of the drift class that cost three commits in one day.

**Implementation:** the production evidence engine is one shared definition.
Each inventory location now provides the candidate names and tiered match used
by both forward discovery and the leftovers sweep. The sweep checks installed
identities with those rules and uses them to attribute records to a bundle Brim
previously removed. Containers, group containers and WebKit locations are in
the inventory. Recent-documents records and dot folders join the sweep.
Apple's own recent-documents records stay out; an installed executable keeps
its command line tool data out, including tools in `~/.local/bin` when the app
has a limited `PATH`. The direction-agreement fixture compares the production
search with the sweep for one bundle across support, preferences, caches,
recent documents, WebKit and group containers.

**Validated:** the package suite, approval tests, Debug build and lint
comparison passed. Fixture tests confirm that installed app data and installed
command line tool settings stay out of the sweep, while the same app's files
appear after removal. T-7.4 is complete; the real-machine row count and
grouping work remain in T-7.5.

### T-7.5 · The list a person can actually read (was P3.1 to P3.6)
- **Objective** 231 rows to roughly 105, every removal citing a file on disk.
- **Depends on** T-7.4.
- **Superseded** `DiagnosticReports` is swept again, but only for reports named for a removed app Brim recorded (`<process>-<date>` or `<process>_<date>`); an unclaimed report is never listed.
- **Work (original)** Exclude `DiagnosticReports` from the sweep while keeping it in the inventory, so an uninstall still clears an application's crash logs by name. Match Apple's own frameworks and daemons by enumerating `/System/Library` at runtime rather than by a list. Consolidate reverse-DNS names on their first two components. Recognise Brim's own residue and swept-domain directories. Uninstall sheet grouping, reusing the leftovers grouping. Temporal-proximity clustering for residue that genuinely arrived together.
- **Acceptance** Re-measured on the real machine, not projected. Every reduction names the record that justified it.
- **Unlocks** a list with a plausible number of rows in it.

**Implementation in the readable-leftovers branch:** `DiagnosticReports`
remains searchable during uninstall but no longer creates anonymous sweep
rows. The sweep reads names present in this Mac's `/System/Library`, skips
nested inventory roots, and protects the running Brim bundle even when it is
a development build outside `/Applications`. It also recognises Brim's older
identifiers. Container manager metadata identifies otherwise opaque UUID
containers; product namespaces keep helpers together while vendor headings
collapse several separate removal choices. The uninstall review groups paths
by location. Its rows retain their individual selection and evidence.

**Read-only measurement on this Mac, 27 September 2026:** the original sweep
listed 270 paths, 12 orphaned and 258 unclaimed. This sweep lists 165 paths,
24 orphaned and 141 unclaimed, under 99 visible headings. These exclusions
have an observed record or installed owner: `/System/Library` entries for
macOS components; the `com.apple.containermanager.identifier` attribute for
Bitcoin2, Binance and MetaTrader UUID containers; the built Brim bundle and
its old identifiers; the installed Claude bundle for `Claude-3p` and three
`Claude - *.workflow` paths; and the installed Antigravity bundle for its
`com.google.antigravity-ide` cache. The `/Users/Shared/Relocated Items`
folders carry macOS's `.localized` marker and contain files moved during an
update, as [Apple documents](https://support.apple.com/guide/mac-help/mchl8ae423a3/mac),
so they are not app residue. A `systemgroup.com.apple` preference is
also Apple-owned. An overlapping `DiagnosticReports` directory is scanned
only through its own inventory rule.

The UUID containers for Bitcoin2 and Binance were created seconds apart,
but their metadata names different products. Time alone would merge unrelated
data into one deletion choice. No temporal cluster was made without a common
owner record. The separate app selections remain available under a vendor
heading. The running app showed the list and the read-only scan did not remove
an application.

### T-7.6 · Plain-language explanation and storage overview (overturns part of C-5)
- **Objective** The two model uses that restate computed facts rather than assert new ones.
- **Depends on** T-6.3, T-7.2.
- **Work** Explain a row from evidence the engine already computed: who owned it, what declared it, when it appeared, what it holds, what returns by itself. Summarise a footprint by what each location is for, from `FootprintProjector` and `LeftoverDomain` figures. Bounded, independent `LanguageModelSession` requests, `@Generable` fact selections rather than prose to parse, and no streaming. Avoid loading the model until a selection is needed. The deterministic renderer from T-6.3 is the floor and remains the fallback whenever the model is unavailable.
- **Acceptance** Every number and every claim in generated text traces to a computed fact. With Apple Intelligence off, the view renders T-6.3's text and nothing about the interface changes shape.
- **Unlocks** the copy problem, structurally: prose stops being hardcoded English and becomes a rendering of evidence.

**Implementation in the readable-leftovers branch:** the model runs only
when computed facts exceed the display limit. Each independent request uses
a fresh `LanguageModelSession`; its transcript is released after the result.
A bounded 32-entry cache retains fact selections, and each request is limited
to 16 facts and 6,000 UTF-8 bytes. A non-streaming `@Generable` result chooses
numbered facts for the leftover explanation or the footprint overview. Brim renders only facts it computed from the
ownership search, `FootprintProjector` and `LeftoverDomain`; it does not use
model-authored names, numbers or removal claims. Invalid choices, model
errors and unavailable Apple Intelligence all use the same deterministic
view. The review sheet keeps its short path, size and action rows, with
evidence behind the Details control.

### T-7.7 · Opaque-name classification (still gated)
- **Objective** Name the ten to fifteen rows nothing deterministic can name.
- **Depends on** T-7.6.
- **Work** A `@Generable` enum over candidate owners, abstention meaning the row says nothing extra rather than growing a badge, accuracy measured on real Brim data before it is trusted.
- **Open question, unanswered** Whether a model-proposed *name* on a row a person may delete crosses C-5's line. Everything else in M7 is independent of the answer.

**M7 done when:** user-selected applications are audited after removal with nothing left behind that Brim can reach; a removal report distinguishes checked, declared-absent and refused-by-macOS; the leftovers sweep and the uninstall path agree for every bundle under test; and no string in the product describes a limitation where a fact would do.

**Remaining live acceptance:** five of the six applications are installed
and their footprints were measured without deletion; Obsidian is absent.
The shared-rule fixture confirms forward and reverse agreement, including
unticked Tier C suffix matches. The user has deferred live removal until
they select the applications and explicitly authorize the audit; six are no
longer required. No live uninstall belongs to the current review and merge
work. This done criterion remains open. T-7.7's owner-name decision also
remains open and does not block the other M7 work.

**Architecture and implementation review, 27 September 2026:** manual
selection now receives the same shared-owner veto as automatic selection.
Nested installed applications and embedded components contribute protective
claims; unreadable ownership never establishes that data is orphaned. Bundle
metadata reads stay within the bundle and have a size limit. Timed-out probes
terminate and reap their child process, with bounded captured output.

Apply revalidation compares the full action semantics. Verification checks
skipped paths and failed record actions instead of reporting success from an
empty set of completed file operations. Rapid checkbox changes coalesce into
one active scan and a final plan for the latest choices. Distinct recorded
identifiers remain separate removal choices even when display names match.

The combined strict Swift package suite and Xcode Debug build passed. Final
lint and focused merge regressions passed before publication. The final visual
recheck could not run because the Mac was locked. No live applications were
removed during this review.

**Responsiveness and removal reliability, 27 September 2026.** Scrolling
lagged in every panel because two menu commands were focused values holding
closures; SwiftUI counted every redraw as new focus state and rebuilt the
menus and window root, so Brim sat at 100% CPU whenever it was frontmost.
`FocusedAction` compares by name. Over the same scroll sequence the main
thread went from busy in 99.8% of samples to 2.7% with the SwiftUI list, so
the AppKit list built for the lag was dropped. Scan fan-out is bounded to four,
cancellation reaches the work, and each section owns its scan.

A leftovers removal skipped three broken links in `~/.local/bin` as needing an
administrator: planning asked the item, through the link, while the sweep asked
the folder. Both now use `RemovalCapability`, which also knows a read-only
folder cannot be moved. The helper sets aside dead command links in
`/usr/local/bin` and `/usr/local/sbin` after proving them dead itself, is
connected for every removal through `HelperRoute`, and is offered once during
setup. `HelperScope` is the planner's reading of the helper's rules, so a plan
promises only what the helper takes and shows the rest as staying before
approval. The sweep no longer lists macOS's `org.cups` files, bundles with an
Apple identifier, or bundles signed by an installed vendor's team. Results
report the outcome recorded for each path and offer Show in Finder.

Measured on this Mac: 163 of 180 leftovers need nothing, 9 dead links need the
helper, and 8 in root-owned folders are shown as staying. With the helper on,
all 9 links were set aside and the daemon log and journal confirmed each one.
Open decision: whether the helper should take other root-owned leftovers, which
needs a way for it to prove each is unused.

---

## 12. Critical path, parallel work, prototypes, risks

### 12.1 Critical path

The longest chain of genuinely blocking work. Everything else can be scheduled around it.

```
T-0.1 → T-0.3/T-0.4 → T-1.1 → T-1.2 → T-1.3 → T-1.4 → T-1.5
      → T-1.6 → T-1.7 → T-1.9 → T-1.10 → T-1.11 → T-1.12
      → T-1.13 → T-1.14 → T-1.15 → T-1.16
      → T-2.1 → T-2.2 → T-2.3 → T-2.4
      → T-3.4 → T-4.5 → release
```

Everything in M5 hangs off T-1.10 and T-2.3 and is off the critical path. The single most schedule-critical decision is **T-1.10 (the plan format)**, because every test and stored record depends on its shape.

### 12.2 Parallelisable

| Can run in parallel | With | Condition |
|---|---|---|
| All five M0 spikes | Each other, and T-0.3/T-0.4 | Independent by construction |
| Every evidence source in T-3.1 | Each other | The source protocol exists from T-1.6 |
| T-5.3, T-5.5, T-5.7, T-5.8 | Each other | All are consumers of the spine |
| T-2.9 (signing pipeline) | Most of M1 | Deliberately early — see risk R-6 |
| T-6.4 (accessibility) | All UI work | Continuous, not a phase |
| Golden tests (T-3.9) | Each new source | Written with the source, not after |

### 12.3 Architecture decisions that must be prototyped before commitment

| Decision | Spike | If the spike fails |
|---|---|---|
| Bulk enumeration as the scanning substrate | S-1 | Budgets loosen; `fts` fallback; no architectural change |
| Signature-based mutual authentication across three bundles | S-2 | A signing certificate becomes a prerequisite for every contributor |
| A root daemon can remove TCC-protected containers | S-3 | **Scope change.** More items become `refusedByOS` and route to vendor uninstallers. Decide before promising complete uninstall |
| AppKit table bridging at scale | S-4 | Lists are paginated; the density rule changes |
| Three-bundle notarisation | S-5 | Bundle layout changes before any feature depends on it |
| Per-process energy counters are real and usable | deferred | Energy becomes a CPU-time-weighted **estimate**, labelled as one, or is cut from V1 |
| BTM output is parseable and stable | deferred | The background view degrades to launchd plus `SMAppService`. It held; `BTMStore` reads the archives directly and the guided reset that was the other half of this row is dropped |

### 12.4 Major technical risks

| # | Risk | Severity | Response |
|---|---|---|---|
| R-1 | A bad deletion in the field | Existential | T-1.13 before any executor; Tier S as a one-way veto; helper re-validation; Trash-first; the four security tests in CI from M2 |
| R-2 | macOS 27 extends protection to more support folders, shrinking coverage | High, structural | Capability pre-checks as a first-class feature (T-2.5); vendor routing (T-3.7); golden tests across the OS matrix; treat each September as planned work |
| R-3 | Undocumented interfaces change (BTM, energy counter semantics) | Medium, recurring | Layered degradation; nothing consequential depends on a parse; deferred spikes with written fallbacks |
| R-4 | Development-time code signing makes mutual authentication unworkable | High, early | S-2 in M0. If it fails, the contributor model changes on day three rather than in month four |
| R-5 | Plan format churn after adapters exist | High | Freeze §3.2 in M1; `formatVersion` from v1; a migration test for every change |
| R-6 | Notarisation or entitlement surprise discovered at release | High | T-2.9 moved into M2, not M6. CI produces a notarised build from the second milestone onward |
| R-7 | Single-maintainer stall | High | Every task finishable in under three days; fixture corpus means development does not require a specific machine; open engine so the work survives |
| R-8 | Scope creep back into "cleaner" | Medium, insidious | Volume I's rejected list is a commitment. Every proposed feature must answer: what evidence does it act on, and how is the result verified |

### 12.5 Definition of done, by milestone

- **M0** — CI green; fixtures deterministic; S-1 to S-5 written up; any scope change from S-3 recorded here.
- **M1** — Uninstall completes end-to-end from the app on the fixture tree and a real disposable app; a service with no window cannot act at all; plan readable before it runs; verification reports a measured delta including honest zeroes; undo works; History records the run with correct requester.
- **M2** — Service out of process; both boundaries authenticate by signature; helper exists with the §3.5 vocabulary and re-validates independently; the four security tests pass in CI; a notarised build installs on a clean machine.
- **M3** — A complex real application (a suite, a security tool, a pkg-installed product) plans correctly; the shared veto demonstrably protects a sibling app; the background view shows more than System Settings.
- **M4** — App Intents report and cannot remove; no service without a window mints a token; every bypass attempt fails closed.
- **M5** — Each feature reports its own coverage gaps honestly; no feature claims bytes it cannot deliver.
- **M6** — Accessibility complete; performance budgets met and published including Brim's own cost; self-removal verified; an update from the previous release installs and self-verifies.

---

## 13. Challenge: what to cut

A plan written once is a plan written optimistically. Six things above are premature or unnecessary.

**C-1 · Cryptographic plan signing — cut.** *(overturns a Volume II detail)*
Volume II describes the plan as "signed, content-addressed", implying a per-install key. Keychain access from a root daemon is awkward, key management is a whole subsystem, and it buys little: the real control is that the helper *re-derives its own authorisation* (T-2.4) and verifies the plan's content hash against the approval token. Content addressing alone gives the integrity binding. §3 above is already written without signing; this note records why. Revisit only if a concrete attack survives T-2.4.

**C-2 · The in-memory artifact graph — cut as a component.**
Volume II named an artifact graph, and it is the right *conceptual* model. Building it as a runtime object is not: footprints are per-identity projections, evidence relations are rows, and a whole-machine graph engine would be built, maintained and never fully traversed. Keep the relational model in the index and the word "graph" in the documentation. Delete the planned `Graph` type. This removes an entire subsystem from M1.

**C-3 · Nine upfront spikes — reduced to five.**
Clone detection, snapshot accounting, energy counters, BTM parsing and root-trash behaviour do not gate the architecture; they gate individual M3 and M5 features. Running them in M0 spends the riskiest weeks answering questions that cannot change the spine. Moved to just-in-time, each with a written fallback (§12.3). Root-trash behaviour folds into S-3.

**C-4 · Rate limiting and abuse shaping on the service (was T-4.7) — cut.**
A local single-user service reached only by signature-verified callers does not need rate limits. Shape anomalies are still *logged* via the journal, which costs nothing, but there is no throttling subsystem. This was security theatre standing in for the control that actually matters, which is the approval gate.

**C-5 · The optional on-device model — out of V1. *Partly overturned by M7; see below.***
Volume I already made it optional, off by default and availability-gated. Everything it would do is presentation over facts the deterministic renderer (T-6.3) already produces. Shipping it in V1 adds an availability matrix, a second explanation path to test, and a feature that is unavailable on ineligible hardware and in unsupported regions. Deterministic explanations ship; the model is the first V1.1 feature, behind the approval boundary built in T-1.12.

*Amended when M7 was written.* The cut was aimed at a model **asserting** something, a name or a judgement on a row somebody is about to delete, and that aim was right. It caught two uses it should not have. Explaining a row and summarising a footprint by what each location is for restate facts the engine already computed and establish none, so they carry none of the risk the cut was defending against, and they fix a problem the deterministic path has proven bad at: hardcoded English drifts into describing Brim's limitations instead of the user's disk. Those two move into V1 as T-7.6, on the explicit condition that T-6.3's renderer stays the floor, so an ineligible Mac loses nothing but polish. **Naming an unattributed folder stays cut** and stays the one open question in T-7.7. The availability matrix argument survives the amendment and is the reason the fallback is a requirement rather than a nicety.

**C-6 · The treemap — out of V1.**
Volume I called it a supporting view, not a headline. The three-number storage account (T-5.3) is what makes the feature credible; the treemap is what makes it look like DaisyDisk. It is the single largest piece of custom drawing in the product and it can be added without touching anything else. Defer.

**Two things that look cuttable and are not.** The shadow-root dry run (T-1.19) looks like test infrastructure but is what lets the pipeline be *executed* in tests rather than simulated — the cheapest insurance against R-1. And T-2.9 looks like release work that belongs in M6; moving it early is the whole mitigation for R-6.

**Net effect:** roughly three weeks removed from the critical path, one subsystem deleted, the riskiest milestone unchanged.

---

## 14. Final V1 sequence

Authoritative. Reflects §13.

| # | Milestone | Contents | Gate to proceed |
|---|---|---|---|
| 0 | **Ground** | T-0.1 to T-0.4; spikes S-1 to S-5 | Fixtures deterministic; five spike findings written; S-3's scope implications recorded |
| 1 | **Spine** | T-1.1 to T-1.19, minus the graph component (C-2), plan signing (C-1) and the CLI (T-1.18) | Uninstall end-to-end from the app, human approval enforced, verified delta, undo, History |
| 2 | **Trust boundary** | T-2.1 to T-2.9 | Out-of-process service, mutual signature authentication, helper with closed vocabulary and independent re-validation, four security tests in CI, notarised build |
| 3 | **Evidence** | T-3.1 to T-3.9 | A real suite application plans correctly; shared veto protects a sibling; background view beats System Settings |
| 4 | **Agents** | T-4.5 and T-4.6 (T-4.1 to T-4.4 dropped, T-4.7 cut) | A read-only agent surface that cannot remove anything; all bypass attempts fail closed |
| 5 | **Features** | T-5.1, T-5.3, T-5.5, T-5.6, T-5.7, T-5.8, T-5.9, parallel and ordered by value | Every feature reports its own coverage gaps; no claimed bytes that cannot be delivered |
| 6 | **Product** | T-6.1 to T-6.8, minus the treemap (C-6) | Accessibility complete; budgets met including Brim's own cost; self-removal verified; update path works |
| 7 | **Complete removal** | T-7.1 to T-7.6; T-7.7 gated | User-selected applications audited after removal with nothing reachable left behind; checked, declared-absent and refused-by-macOS are distinguishable in a report; sweep and uninstall agree per bundle |

**Not in V1, deliberately:** a model that asserts an attribution rather than restating one (T-7.7, gated); the treemap; standing agent policies that pre-authorise future plans; unattended automation of anything destructive; architecture stripping and language pruning; an install watcher of any kind; any adapter that is not the app itself; fleet or MDM features; and every item on Volume I's rejected list.

**The first three commits, in order:** `Package.swift` with the module graph and the compiler-enforced purity of `BrimCore`; the fixture generator; `FileSystemRoot`. Nothing else can be trusted until those exist.

---

## 15. Left out, or drifted, as of 30 September 2026

Left out of 1.0:

- Opaque-name classification (T-7.7), still gated, and the plain-language explanation and storage overview (T-7.6).
- Performance budgets and Brim's own line in the Energy view (T-6.5). There are no signposts or measured budgets; Xcode's review taking 13 seconds was found by hand.
- The 100k-row table bridge (T-6.1). AppKit's table was tried and removed; lists are SwiftUI.
- A notarised build from CI (T-2.9), the Homebrew cask and published code-directory hash (T-6.7), and a licence (T-6.8).
- From the September comparison plan: the three kinds of space with "Free for now", measuring how fast caches come back, large files through Spotlight, brand icons, and the paired-device rule for device support.
- Removed apps' Gone and Kept states with proof history, and "Keep settings".

Built on 30 September, after this list was first written:

- The removal report. Verification returns what was checked and gone, what the app's bundle declares it never had, what is still there, and what macOS kept, each counted apart. Both removal panels show it. This meets the report part of M7's criterion.
- "Replaced by" on Removed apps, only on proof: a record of where the old app was, an installed app with another identifier at exactly that path, and the same developer. The old ChatGPT's rows do not qualify, because nothing records where it was.
- Removing several apps in one review, by Command-click or a table selection. Each app keeps its own plan, approval and report.
- Old versions of command line tools, where a command's link shows which version runs.

Drifted from the plan:

- The service runs in process, not as an XPC service (T-2.1).
- The helper is a closed set of item kinds that proves each item itself, not an executor of plan steps (T-2.3, §3.5).
- Updates installs directly after verifying, where the plan said delegation only (T-5.8), and checks when its page opens rather than only on an explicit action.
- Brim checks GitHub for its own new version once a day on launch without being asked (T-6.7). That is the one network call not started by the person.
- Distribution is a free development certificate without notarisation, not Developer ID (T-2.9).
- Home replaced the ranked review queue (T-6.2).
- Leftovers became Removed apps, one row per app, and then Remnants, with each app as a card and its places inside (T-5.1).
- Coverage from the five-app removal test on 29 Sep: hidden folders in the home folder (declared by an editor's `product.json`, Tier B, or named after the app, Tier C), crash reports by process name and date, and web storage named after a helper's executable. Found but unticked items that are still there after a removal are reported, so "Nothing left" is only said when it is true of everything found.
- The Apps list has a Select button: rows show ticks, and the right pane reviews everything ticked at once. Command-click still works.
- Home's Changes shows the last change that happened, not the difference between the last two snapshots, which was always empty after a relaunch.
- The product rule of two things now names Updates as the one addition.
- Reset and archive (T-5.2) were built in the engine and then removed.


## 16. Registration verification and release boundary, 4 October 2026

The current implementation separates declarations, registration observations
and action receipts. Earlier notes that imply a missing BTM target will be
collected automatically, or that pre-removal declarations prove registration
absence, are superseded by this section.

Implemented:

- Typed present, absent and unknown target observations; atomic surface
  reads with namespace, stable identity, reader version and coverage gaps.
- Exact surviving-copy discovery and shared embedded-identifier protection.
- Exact-domain launchd stop and readback before declaration removal;
  retention on failure, bounded subprocesses and runtime restoration on undo.
- Full receipt payload binding and fresh absence checks, repeated independently
  by the helper before forgetting an installer record. Helper version 12 binds
  the authenticated requesting UID rather than accepting one from the caller.
- Fresh, append-only registration verification in removal results and Journal.
  Newly found records never expand an approved plan.
- Bounded helper-app discovery in selected support/cache folders, exact
  Launch Services cleanup and readback, and identity-checked registration
  restoration when the enclosing folder is put back.
- Grouped remnant removal and explicit protected recovery-copy deletion.
  Protected execution and verification share one authenticated temporary
  process; no persistent background service is installed.
- Provider-data exclusions, precise manual routes and conditional restart advice.
- Background and Home use listed counts and expose partial reads. Details uses
  relevant icons and a leading layout with less indentation.

Bugs found and corrected during implementation:

- A successful PluginKit exit can contain an invalid listing. Parsing now
  validates listing structure and count while retaining useful partial evidence.
- Synthetic job fixtures previously depended on ignored launchctl failures.
  They now inject an explicitly separate runtime; production fails closed.
- The Background inspector revealed the shared BTM archive while displaying
  individual target paths without distinguishing them. Targets and source are
  now labeled separately. Finder reveals only individual targets; the shared
  archive cannot be a fallback. SafetyChecker also protects the archive and
  its parents from explicit removal. Regression tests cover both boundaries.
- Home still claimed registrations were running and a partial scan was clear.
  The real app review exposed this and its status model now preserves read gaps.
- A PluginKit registration experiment created a sandbox container. That unsafe
  experiment was removed and the owned container was deleted through Finder
  with approval. No automatic PluginKit remover is shipped.
- The launchd lifecycle test produced background activity notifications even
  after its job was removed. It was moved out of regular test targets into a
  disposable-account recipe. Future registration experiments use an isolated
  account or VM, because filesystem cleanup cannot guarantee BTM collection.
- Strict compiler checks exposed existing Shortcuts, formatter, lock-result and
  callback capture diagnostics. Small compatibility fixes keep the required
  package and app checks passing.

PluginKit mutation, legacy login-item automation, firewall mutation and
foreign-owner extension/provider operations remain gated. There is no global
reset, private database write or automatic vendor uninstaller.

[The implementation and validation record](uninstall-registration-verification.md)
contains route-specific limits and actual verification evidence. The earlier
research remains the rationale; this section records what has shipped on the
implementation branch rather than declaring every compatibility gate passed.

### Background removal follow-up and deferred work

Open at Login removal and Background App Activity switches are different operations. Remaining user login/background records now receive conditional Open at Login instructions and a direct Settings link, followed by another check. Neither background switches nor restarting are universal erasure guarantees. Exact embedded job labels and domains are saved for post-removal checks, but automatic embedded-job stopping and selective BTM erasure remain unqualified.

Universal removal is deferred for this release. More aggressive shared-store
changes could affect other apps, cross ownership boundaries and add
compatibility and recovery work without a proportionate immediate benefit.
This is a scope decision, not permission to skip discovery or leave known
supported actions broken. Future work should prioritize concrete defects in
attribution, execution, verification and Undo. A new selective adapter needs
legitimate authority, repeatable independent readback and isolated lifecycle
qualification. The linked validation record separates achieved behavior,
unverified cases and optional future research; its deferred experiments are
not the next release task queue.
