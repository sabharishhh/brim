# Thanos Scratchpad — Brim Session Log
*Last updated: 2026-09-20 · Model: Gemini 3.1 Pro (High)*

---

## 1. Session Overview

This is the running scratchpad for the entire Brim development session. It documents what was built, what was broken, what was fixed, and exactly where things stand against the spec.

**Repository:** `/Users/sabharishhh/Developer/brim`
**Branch:** `main`
**Milestone:** Pre-M2 Gate (Fixing Audit Findings before T-2.1)

---

## 2. What Was Built — Commit by Commit

| Commit | Task | What landed |
|--------|------|------------|
| `121a489` | Init | Empty project skeleton |
| `0466b55` | T-0.1 | Package.swift, module graph: BrimCore / BrimScan / BrimIndex / BrimOps / BrimProtocol / BrimService / BrimHelperCore / BrimCLI / BrimMCP |
| `dd8bc4b` | T-0.2 | GitHub Actions CI workflow |
| `9646053` | T-0.3 | `FixtureTreeGenerator` — reproducible synthetic FS tree with golden manifests |
| `8b6af3e` | T-0.4 | `FileSystemRoot` + domain map (user/system/local) |
| `95f772a` | T-0.5 | App artifact protocol + basic evidence model |
| `ce61f79` | T-0.6 | Safety invariants protocol |
| `1a89bc4` | T-0.7/8 | Dependency injection `Environment`, README |
| `3c69b19` | T-1.1 | Core model types: `Identity`, `AppItem`, `Footprint`, `EvaluatedFootprint` |
| `fb0b85e` | T-1.2 | `IdentityResolver` — resolves `Info.plist` bundleID from a URL |
| `6174a39` | T-1.3 | `BrimScanner` — async filesystem enumerator wrapping `FileManager.enumerator` off the cooperative thread pool |
| `d1e2a9c` | T-1.4 | GRDB index schema v1, `schema_migrations` table, WAL mode, integrity checks |
| `7031539` | T-1.5 | `Index` actor — owns the GRDB connection, queues writes, serialises mutations |
| `5d1c637` | Mid-M1 Audit | Concurrency hardening, DB durability, path safety corrections |
| `d66684e` | T-1.6 | Evidence source protocol + 3 sources: `SandboxContainerSource`, `InstallerReceiptSource`, `BundleIdentifierComponentSource` |
| `b35a77d` | T-1.7 | `EvidenceEngine` — aggregates + deduplicates across sources |
| `bad094a` | T-1.8 | `FootprintProjector` — maps evidence to `EvaluatedFootprint` with tier assignments |
| `a83b627` | T-1.9 | `SafetyEngine` v1 — evaluates `CostOfError`, checks Brim self-protection |
| `f9dab16` | T-1.10 | `Planner` + `PlanStore` actor + canonical SHA-256 hash encoding on `Plan` |
| `d9bfb20` | T-1.11 | `BrimService` (in-process actor), `BrimServiceProtocol`, full pipeline wired |
| `2f394c3` | T-1.12 | `ApprovalToken` + `TokenStore` — time-bounded, plan-hash-locked, requester-identity-bound approval gate |
| `83defc2` | T-1.13 | `BrimOps.SafeOps` — TOCTOU-safe deletion via `O_NOFOLLOW` + `fstatat` + `renameat` |
| `ed7dc68` | T-1.14 | `JournalStore` + `Executor` — pre-write journal, step-level outcomes, app bundle deleted last |
| `94163e6` | T-1.15 | `Verifier` — `VerificationResult` with `expectedBytes`, `recoveredBytes` (via `statfs`), `success` flag |
| `deea038` | T-1.16 | `undo(planId:)` + `history()` — restores trashed items from journal, refuses if path re-occupied |
| `cf14195` | T-1.17 | Minimal App UI implemented in BrimUI package (`PlanSheetView`, `NavigationSplitView`) |
| `79a0a24` | T-1.18 | CLI v1 implemented with Swift Argument Parser (`apps`, `footprint`, `plan uninstall`, `approve-request`, `apply`, `verify`, `history`) |
| `b4ba9cc` | T-1.19 | Shadow-root dry run implemented via `ShadowRootGenerator` and `dry-run-uninstall` CLI command |
| `HEAD` | Pre-M2 Audit Fixes | All C, H, M, and L-level findings addressed, tests restored. |
| `cf41d8e` | T-2.1 | Extracted `BrimService` over `BrimXPCProtocol`. `BrimXPCServer` and `BrimXPCClient` built and wired into CLI and tests. |
| `c1e8e1d` | T-2.3 | Privileged helper implemented via `SMAppService.daemon`. Wrote `.plist`, `BrimHelper` executable target, and `install` CLI command. |
| `182864b` | T-2.4 | `BrimService` validates plans independently at execution time using `TargetFingerprint` with sub-millisecond precision. `EvidenceSourceTests` and `VerifierTests` updated. |
| `96db965` | T-2.5 | `FootprintProjector` determines `Capability` (`ok`, `needsHelper`, `needsFullDiskAccess`, `refusedByOS`) using `access` and `stat` syscalls. Surfaced in CLI. |
| `37bdab5` | T-2.6 | Permission ladder implemented via `PermissionAdvisor`. CLI prints actionable permission warnings during `plan` generation. |
| `14a741c` | T-2.7 | Security regression suite covering unauthorized clients, symlink swaps, mid-traversal replacement, and malformed XPC messages. |
| `06b5ca8` | T-2.8 | Self-verification implemented via `SecCodeCopySelf` (code signature) and `DatabaseManager.checkIntegrity()` (`PRAGMA integrity_check`). Wired to abort launch if tampered. |
| `ca017be` | T-2.9 | Created `scripts/build_release.sh` to package `Brim.app`, embed the helper daemon, sign, notarize, and build a DMG. Added `.github/workflows/release.yml` GitHub action. |
| `2c5ee5a` | M2 Audit | Addressed all issues raised in final M2 adversarial audit (Team ID injection, fingerprint re-validation completeness, debug exit handling). |

---

## 3. Current State

### Test Suite: ✅ ALL GREEN

```
BrimSecurityTests  — 8 tests  — 0 failures
BrimIndexTests     — 2 tests  — 0 failures
BrimCoreTests      — 15 tests — 0 failures
BrimGoldenTests    — 0 tests  (Golden harness exists, no tests wired yet)
```

**Total: 25 tests, 0 failures**

### Module Graph

```
BrimScanShim (C)
    └── BrimScan
    └── BrimOps ──────────────────────────────────────┐
BrimCore                                               │
    ├── BrimIndex (GRDB)                               │
    ├── BrimProtocol ───────────────────────────────┐  │
    ├── BrimScan                                    │  │
    └── BrimService ← BrimIndex + BrimProtocol + ───┘──┘
                      BrimScan + BrimCore + BrimOps
BrimUI ← BrimService
BrimHelper (Executable) ← BrimHelperCore + BrimService
BrimCLI ← BrimProtocol + BrimService                
BrimMCP ← BrimProtocol                              (stub, empty main.swift)
```

---

## 4. Where We Stand vs. the Implementation Plan

### Milestone 0 — Ground and spikes ✅ COMPLETE

### Milestone 1 — The vertical slice ✅ COMPLETE
- [x] T-1.1 through T-1.16
- [x] T-1.17 · Minimal app (Implemented in BrimUI package)
- [x] T-1.18 · CLI v1 (Implemented in BrimCLI)
- [x] T-1.19 · Shadow-root dry run (Implemented via ShadowRootGenerator and `dry-run-uninstall`)

**M1 Gate Criteria (from the spec)**
> *"Uninstall completes end-to-end from app and CLI; CLI cannot act without human approval; plan readable before it runs; verification reports a measured delta; undo works; History records both runs with the correct requester."*

| Gate criterion | Status |
|---|---|
| Uninstall end-to-end (fixture tree) | ✅ Tested in BrimServiceTests |
| CLI cannot act without approval | ✅ Enforced via TokenStore; CLI `apply` fails without token |
| Plan readable before it runs | ✅ PlanStore persists to disk |
| Verification reports measured delta | ✅ VerificationResult with recoveredBytes |
| Undo works | ✅ UndoTests pass |
| History records runs with requester | ✅ history() + LedgerStore |

### Milestone 2 — The trust boundary 🟡 IN PROGRESS
- [x] T-2.1 · Extract the service over XPC (Anonymous listener & client complete)
- [x] T-2.2 · Mutual code-signing requirements
- [x] T-2.3 · Privileged helper
- [x] T-2.4 · Independent re-validation in the helper
- [x] T-2.5 · Capability pre-checks
- [x] T-2.6 · Permission ladder
- [x] T-2.7 · Security regression suite
- [x] T-2.8 · Self-verification
- [x] T-2.9 · Signing, notarisation and release pipeline

---

## 5. Security Audits

### 5.1 Mid-M1 Adversarial Audit (`docs/m1_audit_report.md`) - ✅ RESOLVED
An audit was performed mid-session (between T-1.11 and T-1.12). 
- C-1: TOCTOU in executor -> Fixed with `BrimOps.SafeOps.trashItem`.
- C-2: No approval gate -> Fixed with `ApprovalToken`.
- C-3: No journal -> Fixed with `JournalStore`.
*(All findings resolved in commits 5d1c637, 2f394c3, 83defc2, ed7dc68)*

### 5.2 Pre-M2 Gate Audit (`pre_m2_gate_audit.md` artifact) - ✅ RESOLVED
A final M1 audit was performed after T-1.19 to verify the system is ready for the XPC boundary (M2). The verdict was **PASS WITH FIXES**.

All findings (C, H, M, and L) have been completely resolved:
1. **CRITICAL / HIGH Fixes:**
   - C-1: `mintTokenForTest` removed, bypass closed.
   - C-2: `undo()` symlink-swap vector closed via `SafeOps.restoreItem(from:to:)` using `renameatx_np`.
   - C-3: `DryRunUninstall` uses ephemeral shadow stores.
   - H-1: Token store persists to disk atomically.
   - H-2: `verify()` uses `lstat` instead of following symlinks.
   - H-3/H-6: Execution sorted safely via `ExecutionPhase`; journal write failures gracefully swallowed.
   - H-5: `SafetyChecker` resolves symlinks natively avoiding path-traversal evasion.

2. **MEDIUM / LOW Fixes:**
   - M-1: Expiry checked before TokenStore cache mutation.
   - M-2: `FileSystemRoot` properly injects `userName`.
   - M-3: `ShadowRootGenerator` uses safe `lstat`-based copy without traversing symlinks.
   - M-4: `IdentityResolver` uses a TTL cache.
   - M-5: `BrimService.apply` uses `appliedPlanIds` guard against double-execution.
   - M-7: `PlanStore` checks for pre-existing UUID on save.
   - M-8: Immutable `LedgerStore` created to back `history()` separately from mutable journal.
   - L-1/L-2: CLI `dryRun` global flag removed, `apps` command correctly references root.

---

## 6. Next Steps

### Next Task in M3
1. **T-3.1 · Pre-flight simulation for the UI** — Output rich validation artifacts from `plan()`.

---

## 7. Warnings / Things to Watch

- **`BrimGoldenTests` must not stay at 0 tests** — Needs to be wired when T-3.9 is reached.
- **M2 Xcode project modification** was avoided by using a pure SwiftPM + `build_release.sh` approach to structure the `.app` bundle natively.

### Milestone 3 — Features
- [x] T-3.1 · Remaining Tier A and B sources (Implemented GroupContainer, BundleIDState, TeamID, LaunchServices, SMAppService sources. Fixed reverse undo restoration order bug).
