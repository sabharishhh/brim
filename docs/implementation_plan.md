# Brim — Implementation Plan

**Status:** authoritative build plan. Derived from Volume I (product research) and Volume II (architecture, agents, security). Those two documents are the specification; this one does not revisit their decisions.

**Audience:** an implementing agent or developer working task-by-task from an empty repository.

**Reading order:** §1 (invariants) and §2 (layout) before any code. §3 (frozen contracts) before any task in M1. §13 and §14 are authoritative wherever they conflict with the task catalogue — the catalogue is written first and then cut.

---

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
  "requester": { "kind": "app|cli|mcp|intent", "identity": "signed-identity-string" },
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

```swift
public protocol BrimHelperProtocol {
  func executeStep(planPath: URL, planHash: String, index: Int,
                   reply: @escaping (StepOutcome) -> Void)
  func helperVersion(reply: @escaping (String) -> Void)
  func uninstallSelf(reply: @escaping (Bool) -> Void)
}
```

The helper reads the plan from a directory writable only by root and Brim's signed components, recomputes `planHash` and refuses on mismatch, then **re-runs the evidence and safety checks for that step using `BrimCore`** before touching anything.

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

**Goal:** uninstall one application end-to-end, from two different adapters, with the approval gate real and the result verified. No helper, no XPC transport, no privileged paths. Everything else in Brim is an extension of this spine.

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
- **Unlocks** both adapters; the M2 extraction.

### T-1.12 · Approval gate and token store
- **Objective** The boundary that makes agents safe, built before any agent exists.
- **Depends on** T-1.11.
- **Work** `requestApproval` records a pending request and signals the UI. Human approval in the app mints an `ApprovalToken` (§3.3). In-memory store, single use, consumed on apply, expiry enforced, requester bound. No API path produces a token.
- **Acceptance** Tests prove: apply without a token fails; with an expired token fails; with a token for a different plan hash fails; with a replayed token fails; with a token minted for a different requester fails. A grep test asserts no function in the codebase returns `ApprovalToken` except the UI-triggered mint.
- **Unlocks** the CLI, and all of M4.

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
- **Unlocks** approval for every other adapter.

### T-1.18 · CLI v1
- **Objective** Prove the adapter model with a second client on day one.
- **Depends on** T-1.11, T-1.12.
- **Work** `brim apps`, `brim footprint <identity>`, `brim plan uninstall <identity>`, `brim approve-request <planHash>`, `brim apply <planHash> --token <t>`, `brim verify <planHash>`, `brim history`. `--json` on everything, stable exit codes, `--dry-run`.
- **Acceptance** The CLI can complete an uninstall **only** after a human approves in the app. A scripted attempt to apply without approval fails with a clear, non-guessable error.
- **Unlocks** M4 with almost no additional work.

### T-1.19 · Shadow-root dry run
- **Objective** Run the entire pipeline against a copy, for tests and for a user-facing preview.
- **Depends on** T-1.14.
- **Work** A mode where `FileSystemRoot` points at a copied tree and all mutations apply there. Wired end-to-end, including verification.
- **Acceptance** A full uninstall in dry-run mode changes nothing outside the shadow root, and produces a `VerificationResult` comparable to the real one.
- **Unlocks** safe development; regression tests that execute rather than simulate.

**M1 done when:** on both the fixture tree and a real machine with a disposable app, an uninstall completes from the app and from the CLI; the CLI cannot act without human approval; the plan is readable before it runs; the verification reports a measured delta; undo works; History records both runs with the correct requester. **No privileged paths, no helper, no XPC yet.**

---

## 6. Milestone 2 — The trust boundary

**Goal:** make the process topology and the privilege boundary real, with the security properties tested rather than intended. Nothing user-visible is added.

### T-2.1 · Extract the service over XPC
- **Objective** One index owner, one permission identity, many clients.
- **Depends on** M1 complete, S-2.
- **Work** Move `BrimService` into an XPC service bundle inside the app. Add the XPC `ServiceClient` implementation behind the existing abstraction. An actor wrapper around `NSXPCConnection` to satisfy strict concurrency. Interface whitelisting for collection types. Invalidation and reconnection handling.
- **Acceptance** All M1 tests pass unchanged against the XPC client. Killing the service mid-request surfaces a clean error and reconnects.
- **Unlocks** the service running without the app in the foreground.

### T-2.2 · Mutual code-signing requirements
- **Objective** Only Brim's own signed components can reach the service or the helper.
- **Depends on** T-2.1, S-2.
- **Work** `setCodeSigningRequirement` applied on both directions, **before the interface is exported**, never after. Separate requirement strings for release and development builds, with the development path impossible to enable in a Developer ID build. Never use the process identifier.
- **Acceptance** A test client signed with a different identity is rejected. A grep test asserts `processIdentifier` is never read for an authorisation decision.
- **Unlocks** the helper.

### T-2.3 · Privileged helper
- **Objective** Root, with a vocabulary too small to abuse.
- **Depends on** T-2.2, S-3, T-1.13.
- **Work** `SMAppService` daemon. Registered on first need, not at launch. Implements §3.5 only. Reads the plan from the protected plan store, recomputes the hash, refuses on mismatch. **Uses `BrimOps` unchanged** — the same code the unprivileged executor uses.
- **Acceptance** Registration and complete removal both work; the helper refuses a plan whose file has been modified after approval; a direct connection attempt from an unsigned process is rejected.
- **Unlocks** system-domain removal, BTM access, privileged energy sampling.

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

### T-2.9 · Signing, notarisation and release pipeline
- **Objective** Discover distribution problems now, not at release.
- **Depends on** S-5, T-2.3.
- **Work** CI job producing a Developer ID signed, hardened-runtime, notarised, stapled build of the app with its XPC service and daemon. Publish the code-directory hash as a release artefact. Keys in the CI secret store, signing isolated in its own job.
- **Acceptance** The notarised artefact installs on a clean machine, registers the daemon and passes T-2.8.
- **Unlocks** every subsequent milestone shipping as a testable build.

**M2 done when:** the service runs out of process, both boundaries authenticate by signature, the helper exists with the §3.5 vocabulary and re-validates independently, the four security tests pass, and CI produces a notarised build.

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
- **Depends on** T-2.3, deferred spike on `sfltool dumpbtm`.
- **Work** Invoke `sfltool dumpbtm` through the helper; parse into records; join to identities; mark records whose owner no longer exists. **Treat parsing as an enrichment layer**: a parse failure degrades the view to launchd plus `SMAppService` status and never blocks an action.
- **Acceptance** With parsing deliberately disabled, the background view still renders and targeted removal still works. A synthetic malformed dump produces a degraded view, not an error dialog.
- **Unlocks** the guided reset.

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
- **Dropped** the guided `btmReset` flow. `sfltool resetbtm` deregisters every login item on the Mac at once, and the case it would have fixed does not exist: `backgroundtaskmanagementd` collects records for deleted apps by itself, which the Background view already reports as "macOS is catching up". The step, the restore list, the capture and the store were all removed.

### T-3.9 · Evidence golden tests per OS version
- **Objective** Notice when Apple changes the ground.
- **Depends on** T-3.1.
- **Work** Snapshot the evidence output for the fixture corpus, stamped with engine revision and OS version. CI runs against the supported OS matrix; a diff is a reviewable failure, not a silent change.
- **Acceptance** Changing a source without updating snapshots fails CI with a readable diff.
- **Unlocks** surviving each September.

**M3 done when:** a full uninstall plan for a real, complex application (a suite, a security tool, a pkg-installed product) is correct, the shared veto is demonstrably protecting sibling apps, and the background-items view shows more than System Settings does.

---

## 8. Milestone 4 — Agent surfaces

**Goal:** three adapters over one API. Nearly free, because the gate already exists.

### T-4.1 to T-4.4 · Dropped
Brim shipped an MCP server and a command line tool. Both were removed, along
with the requester-labelling and untrusted-string work that existed to make
them safe. Neither was broken; neither was the product. The approval gate
that was designed around them stays exactly as it is, because the rule it
enforces — that nothing outside Brim's own process has a method that mints
approval — is what makes the app safe to give root to, adapters or not.

### T-4.5 · App Intents
- **Objective** Apple's own agent surface, safely.
- **Depends on** T-2.1.
- **Work** Read-only intents (storage summary, background-item count, app footprint, update status) plus one intent that opens a plan for review. Entities for applications and plans. Nothing destructive reachable from an unattended automation.
- **Acceptance** A Shortcuts automation running with nobody present can report, and cannot remove anything.
- **Unlocks** Spotlight and Shortcuts reach.

### T-4.6 · Agent safety test suite
- **Objective** The capability table, enforced by tests rather than by intent.
- **Depends on** T-4.1, T-4.2.
- **Work** Tests for: approval attempted through every adapter; token replay, expiry, wrong plan, wrong requester; a plan mutated after approval; an injected filename attempting to steer a tool result; a model-shaped input naming an out-of-plan target.
- **Acceptance** All fail closed, with reasons recorded in the journal.
- **Unlocks** the strongest differentiator in the product.

**M4 done when:** the same uninstall completes identically from the app, the CLI and an MCP host, with the approval window raised in all three cases, and every bypass attempt in T-4.6 fails.

---

## 9. Milestone 5 — Feature expansion

Every task here is an extension of the spine. They parallelise almost completely; the ordering below is by value, not by dependency.

### T-5.1 · Leftovers and orphans
- **Objective** Volume I's two-category model.
- **Depends on** T-3.1, T-3.4.
- **Work** Before declaring anything orphaned, search all mounted volumes, readable user accounts, Launch Services registration and installer receipts for an owner. **Orphaned** = owner recorded present and now gone, or a receipt exists for an absent product; pre-selectable. **Unclaimed** = unattributable after that search; shown, sorted by size, never pre-selected. Use access times to sort, never to justify.
- **Acceptance** The fixture's second-volume app is not reported as orphaned. The two categories are never merged in the UI or the API.
- **Unlocks** the leftovers view.

### T-5.2 · Reset and archive
- **Objective** Two lifecycle actions on the existing graph.
- **Depends on** T-1.8.
- **Work** **Reset**: the same footprint with a filter that keeps the bundle and identifiable licence/keychain material and removes state. **Archive**: export bundle + data + a manifest, then optionally proceed to uninstall.
- **Acceptance** A reset app launches as if new and retains its licence. An archived app restores from the export.
- **Unlocks** two underserved jobs at near-zero cost.

### T-5.3 · Storage account
- **Objective** The three numbers, always together.
- **Depends on** T-1.3, deferred spike on snapshot accounting.
- **Work** Logical size from enumeration; reclaimable from the evidence model; snapshot-pinned and purgeable from volume and snapshot enumeration. Never collapse them into one figure.
- **Acceptance** On a machine with local snapshots, the pinned figure is non-zero and the reclaimable figure excludes it. A deletion that frees nothing is explained rather than reported as success.
- **Unlocks** the category's most credible feature.

### T-5.4 · Duplicates
- **Objective** Honest savings, cheaply computed.
- **Depends on** T-1.3, deferred spike on clone detection.
- **Work** Size class, then a sparse fingerprint over head, tail and length, then a full hash only for survivors. Hardware-accelerated SHA-256 is the default. **Disable caching on large one-shot passes** so the scan does not evict the user's working set. Exclude clone-linked pairs from the savings total and label them as already sharing storage.
- **Acceptance** A cloned file pair is reported as duplicates with zero recoverable bytes. A 100 GB pass leaves the page cache measurably intact compared to a naive read.
- **Unlocks** the commodity feature, done better.

### T-5.5 · Energy sampler
- **Objective** Real joules, accumulated.
- **Depends on** T-2.3, deferred spike on energy counters.
- **Work** Sample `proc_pid_rusage` with `RUSAGE_INFO_V6` at a low cadence; persist deltas; aggregate by coalition where available and by bundle path otherwise. Opt-in persistent agent registered via `SMAppService`, **listed by Brim in its own background-items view**. Root-owned processes read through the helper when available, marked as a coverage gap otherwise.
- **Acceptance** Energy accumulates across app restarts. Coverage gaps are displayed, not hidden. Turning the feature off removes the agent completely.
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

### T-5.8 · Updates
- **Objective** Coverage without a database.
- **Depends on** T-1.2.
- **Work** Discover a Sparkle feed from the bundle, a Homebrew cask match, or App Store provenance. State the source per app, and treat "no automatic update source" as a reportable finding. Install by delegation only — drive Sparkle, invoke `brew`, hand off to the App Store. Network access only on explicit user action, only to URLs already present in installed bundles.
- **Acceptance** With networking disabled, the view renders from local state and says so. A test asserts no update check occurs without a user action.
- **Unlocks** a category vacated in January 2026.

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

### T-6.2 · Review queue
- **Objective** The landing surface.
- **Depends on** T-3.4, T-5.9.
- **Work** Rank findings by confidence times impact. Show a count and a byte total. No score, no percentage, no health colour. Populate progressively as evidence arrives.
- **Acceptance** The first window on a clean install shows real findings with no permission grant.

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
- **Work** Brim lists its own agent in the background-items view on the same terms as everything else. A self-removal flow that removes the app, the helper, the agent, the index and every registration, then verifies.
- **Acceptance** After self-removal, a scan from a fresh build finds nothing belonging to Brim.

### T-6.7 · Sparkle and release engineering
- **Objective** Ship, repeatedly and safely.
- **Depends on** T-2.9.
- **Work** Sparkle 2 with signature verification, a compiled-in feed URL and a pinned public key. Versioning, release notes, Homebrew cask, published code-directory hash per release, defensive domain registration, a single documented official origin.
- **Acceptance** An update from the previous release installs and passes self-verification.

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

### T-7.1 · The measured misses (was P1.1 to P1.7)
- **Objective** Recover what the removal path provably leaves behind today.
- **Depends on** nothing. Deliberately first, because T-7.2 is weeks and this is days.
- **Work** `CFBundleName` in `LocationInventorySource.candidates`, with a test holding `LeftoversScanner` and `LocationInventorySource` to one answer for one bundle. `~/.config`, `~/.cache`, `~/.local/{bin,share,state}` and vendor dotfile directories, name-matched, Tier C. `bundleIdentifierPrefix` in caches and application support, which catches `<id>.ShipIt`. Launch Services recent-documents `.sfl4`, with §11.1's guard landed as a test first. Team identifier resolution in `IdentityResolver`. Symlinks pointing into an installed bundle.
- **Acceptance** The same six applications re-measured, with the before and after written down. VS Code's 143 MB and Claude's 189 MB are in the footprint. A test fails if any scanner resolves a path recorded in a `.sfl4` into a scan target.
- **Unlocks** the two largest numbers on the board, in days.

### T-7.2 · Capability-derived search (was P2.1 to P2.3)
- **Objective** Replace category reasoning with the application's own declarations.
- **Depends on** T-7.1, T-1.2, T-3.1.
- **Work** `IdentitySurface`: every name a bundle answers to, from `Info.plist`, the signature, and embedded helpers, XPC services and app extensions. `CapabilitySurface`: entitlements and declarations mapped to the record classes that can exist, so `NEProviderClasses` implies a network extension and `com.apple.security.device.camera` implies one TCC entry. Planning consumes both. Unsigned and ad-hoc bundles thin the capability surface to `Info.plist` alone and that is a `RegistrationCoverage` gap, reported as one.
- **Acceptance** An uninstall reports what it checked *and* what the application declared it had none of, and the two are distinguishable in the report. No app names appear in the implementation. A name-derived match is Tier C whatever produced the name.
- **Unlocks** negative evidence, which is the only honest way to say a surface is clean.

### T-7.3 · The removal ceiling, reported rather than hidden (was P2.4, P2.5)
- **Objective** Say what macOS will not allow, once, in the right place.
- **Depends on** T-7.2, T-3.3.
- **Work** Three capability tiers as a first-class outcome: removable; removable only destructively (Background Task Management has no per-item API, `sfltool resetbtm` is all-or-nothing, which is why Brim does not offer it); detectable but not removable (a system extension or VPN configuration belonging to a departed application, and TCC entries for a bundle that is already gone, because `tccutil` resolves through Launch Services). Background Task Management needs no action of its own: macOS collects records for deleted applications itself.
- **Acceptance** A tier-3 outcome names the one action that does work rather than describing what Brim cannot do.
- **Unlocks** an honest completion claim, and closes the last dead step kind.

### T-7.4 · Leftovers re-derived from the removal engine (was P2.6)
- **Objective** One engine, two directions.
- **Depends on** T-7.2.
- **Work** An orphan search is the identity surface and the location rules run from the record towards the owner instead of from the owner towards the record. Shared tier model, shared rules, one implementation.
- **Acceptance** A test binds the two directions: for one bundle, what the uninstall would remove and what the sweep attributes to it are the same set.
- **Unlocks** the end of the drift class that cost three commits in one day.

### T-7.5 · The list a person can actually read (was P3.1 to P3.6)
- **Objective** 231 rows to roughly 105, every removal citing a file on disk.
- **Depends on** T-7.4.
- **Work** Exclude `DiagnosticReports` from the sweep while keeping it in the inventory, so an uninstall still clears an application's crash logs by name. Match Apple's own frameworks and daemons by enumerating `/System/Library` at runtime rather than by a list. Consolidate reverse-DNS names on their first two components. Recognise Brim's own residue and swept-domain directories. Uninstall sheet grouping, reusing the leftovers grouping. Temporal-proximity clustering for residue that genuinely arrived together.
- **Acceptance** Re-measured on the real machine, not projected. Every reduction names the record that justified it.
- **Unlocks** a list with a plausible number of rows in it.

### T-7.6 · Plain-language explanation and storage overview (overturns part of C-5)
- **Objective** The two model uses that restate computed facts rather than assert new ones.
- **Depends on** T-6.3, T-7.2.
- **Work** Explain a row from evidence the engine already computed: who owned it, what declared it, when it appeared, what it holds, what returns by itself. Summarise a footprint by what each location is for, from `FootprintProjector` and `LeftoverDomain` figures. One retained `LanguageModelSession`, `prewarm()` on the shared prefix, `@Generable` types so the output is a value and never prose to parse, no streaming. The deterministic renderer from T-6.3 is the floor and remains the fallback whenever the model is unavailable.
- **Acceptance** Every number and every claim in generated text traces to a computed fact. With Apple Intelligence off, the view renders T-6.3's text and nothing about the interface changes shape.
- **Unlocks** the copy problem, structurally: prose stops being hardcoded English and becomes a rendering of evidence.

### T-7.7 · Opaque-name classification (still gated)
- **Objective** Name the ten to fifteen rows nothing deterministic can name.
- **Depends on** T-7.6.
- **Work** A `@Generable` enum over candidate owners, abstention meaning the row says nothing extra rather than growing a badge, accuracy measured on real Brim data before it is trusted.
- **Open question, unanswered** Whether a model-proposed *name* on a row a person may delete crosses C-5's line. Everything else in M7 is independent of the answer.

**M7 done when:** the same six applications are re-measured with nothing left behind that Brim can reach; a removal report distinguishes checked, declared-absent and refused-by-macOS; the leftovers sweep and the uninstall path agree for every bundle under test; and no string in the product describes a limitation where a fact would do.

---

## 12. Critical path, parallel work, prototypes, risks

### 12.1 Critical path

The longest chain of genuinely blocking work. Everything else can be scheduled around it.

```
T-0.1 → T-0.3/T-0.4 → T-1.1 → T-1.2 → T-1.3 → T-1.4 → T-1.5
      → T-1.6 → T-1.7 → T-1.9 → T-1.10 → T-1.11 → T-1.12
      → T-1.13 → T-1.14 → T-1.15 → T-1.16
      → T-2.1 → T-2.2 → T-2.3 → T-2.4
      → T-3.4 → T-4.1 → release
```

Everything in M5 hangs off T-1.10 and T-2.3 and is off the critical path. The single most schedule-critical decision is **T-1.10 (the plan format)**, because every adapter, test and stored record depends on its shape.

### 12.2 Parallelisable

| Can run in parallel | With | Condition |
|---|---|---|
| All five M0 spikes | Each other, and T-0.3/T-0.4 | Independent by construction |
| T-1.17 (app) and T-1.18 (CLI) | Each other | After T-1.11 freezes the protocol |
| Every evidence source in T-3.1 | Each other | The source protocol exists from T-1.6 |
| T-5.3, T-5.4, T-5.5, T-5.7, T-5.8 | Each other | All are consumers of the spine |
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
| BTM output is parseable and stable | deferred | The background view degrades to launchd plus `SMAppService`; the guided reset still ships |
| APFS clone detection | deferred | Duplicates ship without clone-aware savings and say so |

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
- **M1** — Uninstall completes end-to-end from app and CLI on the fixture tree and a real disposable app; the CLI cannot act without human approval; plan readable before it runs; verification reports a measured delta including honest zeroes; undo works; History records both runs with correct requester.
- **M2** — Service out of process; both boundaries authenticate by signature; helper exists with the §3.5 vocabulary and re-validates independently; the four security tests pass in CI; a notarised build installs on a clean machine.
- **M3** — A complex real application (a suite, a security tool, a pkg-installed product) plans correctly; the shared veto demonstrably protects a sibling app; the background view shows more than System Settings.
- **M4** — The same uninstall completes identically from app, CLI and an MCP host, with the approval window raised in all three; every bypass attempt fails closed.
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
Volume I already made it optional, off by default and availability-gated. Everything it would do is presentation over facts the deterministic renderer (T-6.3) already produces. Shipping it in V1 adds an availability matrix, a second explanation path to test, and a feature that is unavailable on ineligible hardware and in unsupported regions. Deterministic explanations ship; the model is the first V1.1 feature, behind the boundary already built in T-4.2.

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
| 1 | **Spine** | T-1.1 to T-1.19, minus the graph component (C-2) and plan signing (C-1) | Uninstall end-to-end from app and CLI, human approval enforced, verified delta, undo, History |
| 2 | **Trust boundary** | T-2.1 to T-2.9 | Out-of-process service, mutual signature authentication, helper with closed vocabulary and independent re-validation, four security tests in CI, notarised build |
| 3 | **Evidence** | T-3.1 to T-3.9 | A real suite application plans correctly; shared veto protects a sibling; background view beats System Settings |
| 4 | **Agents** | T-4.1 to T-4.6 (T-4.7 cut) | Identical uninstall from three adapters; all bypass attempts fail closed |
| 5 | **Features** | T-5.1, T-5.2, T-5.3, T-5.4, T-5.5, T-5.6, T-5.7, T-5.8, T-5.9 — parallel, ordered by value | Every feature reports its own coverage gaps; no claimed bytes that cannot be delivered |
| 6 | **Product** | T-6.1 to T-6.8, minus the treemap (C-6) | Accessibility complete; budgets met including Brim's own cost; self-removal verified; update path works |
| 7 | **Complete removal** | T-7.1 to T-7.6; T-7.7 gated | Six applications re-measured with nothing reachable left behind; checked, declared-absent and refused-by-macOS are distinguishable in a report; sweep and uninstall agree per bundle |

**Not in V1, deliberately:** a model that asserts an attribution rather than restating one (T-7.7, gated); the treemap; standing agent policies that pre-authorise future plans; unattended automation of anything destructive; architecture stripping and language pruning; an install watcher of any kind; HTTP transport for MCP; fleet or MDM features; and every item on Volume I's rejected list.

**The first three commits, in order:** `Package.swift` with the module graph and the compiler-enforced purity of `BrimCore`; the fixture generator; `FileSystemRoot`. Nothing else can be trusted until those exist.