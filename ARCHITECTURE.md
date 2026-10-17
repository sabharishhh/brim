# Architecture

This is a map of the code for people who want to fix something or add to
it. For setup and the checks a change has to pass, see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

```
Brim/                    The macOS app: SwiftUI views, the window shell and design system
Brim.xcodeproj/          Xcode project for the app and the helper
BrimCore/                Swift package holding everything that is not interface
  Sources/<module>/      One folder per module, listed below
  Tests/<suite>/         Test targets, listed below
Helper/                  Entry point of the temporary administrator process
Services/FeedbackRelay/  Cloudflare Worker that files feedback as GitHub issues
Support/                 The app's Info.plist
scripts/                 Release build, lint check and development tools
.github/                 CI, the release workflow and issue templates
```

The app target is thin. Views in `Brim/` read view models from `BrimUI`,
and all scanning, planning and removal happens in the package, where it can
be tested without a window.

## Modules

| Module | What it holds |
| --- | --- |
| `BrimCore` | Models and rules every other module shares: identities, evidence tiers, footprints, plans, the planner, safety checks and the locations where software keeps data. It depends on nothing. |
| `BrimScan` | Detection. Lists installed apps, finds what an app owns, sweeps for remnants, reads background items and update sources. |
| `BrimOps` | Changes to the disk: moving to the Trash, clearing preferences, Launch Services, installing updates. |
| `BrimService` | The service the app talks to. It plans, asks for approval, runs plans through the executor, verifies the result and keeps the journal. |
| `BrimProtocol` | The service's protocol and the approval types. |
| `BrimIndex` | History of every app list Brim has taken, stored with GRDB, so changes are worked out by comparing snapshots. |
| `BrimPrivileged` | The temporary administrator process: what it accepts, how it checks its client and how it removes protected items. |
| `BrimProcess` | Running command line tools with a deadline. |
| `BrimScanShim` | A small C wrapper around `getattrlistbulk`. |
| `BrimUI` | View models for each page of the app. |
| `BrimJobHelper` | The package's build of the administrator process, so tests reach the same code the app ships. |

## How a removal works

1. `BrimScan` builds the app's footprint from several evidence sources.
   Each item carries a tier (A, B or C for how sure Brim is, S for shared
   with another app) and a sentence saying how Brim knows.
2. `BrimCore`'s planner turns the selected items into a plan of steps.
   Anything that cannot happen is listed as staying, with its reason.
3. The person approves the plan in Brim's window. Only `BrimService` can
   grant approval, and only for the plan that was reviewed.
4. The executor runs the steps, sending protected items to the
   administrator process, and records each outcome in the journal.
5. Verification looks at every path again and reports what went, what
   stayed and what could not be checked.

## Tests

| Suite | What it covers |
| --- | --- |
| `BrimCoreTests` | Rules, matching, planning and scanning against fixture trees |
| `BrimSecurityTests` | Approval, execution, undo and the administrator process |
| `BrimUITests` | View models, with stub services |
| `BrimIndexTests` | History storage and migrations |
| `BrimRealEnvironmentTests` | The real Mac. Runs only with `BRIM_REAL_ENV=1` |
| `BrimFixtures` | Shared fixture trees, not a suite of its own |

Removals in tests never reach your real Trash. Under XCTest, files go to a
temporary folder that is emptied when the run ends.

## Scripts

`build_release.sh` and `verify_release.sh` make and check a release (see
[RELEASING.md](RELEASING.md)), and `lint_changes.py` is the lint check CI
runs. Three are for development: `coverage_diff.sh` lists what a removal
left on disk without relying on Brim's own search, `ax_tree.swift` prints
the app's accessibility tree, and `stale_builds.sh` finds and removes old
copies of Brim that macOS could open instead of the one you built.

## Where to start

- A wrong owner or a missed file: the evidence sources in
  `BrimScan/Sources` and the location rules in `BrimCore/FS`.
- A new kind of removal step: the planner in `BrimCore/Model/Plan` and the
  executor in `BrimService`, together. A test fails if a step kind has no
  producer or no handler.
- Something on screen: the page in `Brim/Views` and its view model in
  `BrimUI`.
