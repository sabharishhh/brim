# Brim, in brief

Brim traces what software owns on your Mac, removes approved items and
records what is gone, what remains and what could not be checked.

It is a native Mac utility with one main window. It builds an evidence-backed
record of each app's footprint, its background registrations, the space it
takes and what it left after removal, and lets the person remove, verify and
put back. The difference from a cleaner is that every row says how Brim
knows, and nothing is ticked on a guess.

## Decisions

| Area | Decision |
|---|---|
| Platform | macOS 27 and later, Apple silicon first. The helper builds for macOS 15. |
| Stack | Swift 6, SwiftUI with AppKit where it is better. No Rust. |
| Data | Local only, no account. A SQLite index of snapshots, a plan store and a removal journal on the Mac. |
| Network | Only for updates: the App Store, Homebrew's catalog, each app's own feed, and GitHub for Brim itself. |
| Permissions | Full Disk Access during setup. Protected cleanup shares administrator authentication for the selected batch, then the temporary process exits. No persistent background helper. Permanent user-level actions require a presence check; moving writable items to Trash needs no authentication. |
| Distribution | Direct download from GitHub Releases, signed with a free Apple Development certificate and not notarised. People open it once through Privacy & Security, Open Anyway. |
| Price | Free and open source for 1.0. Licence still to be chosen. |
| Quality bar | Wrong deletion is unacceptable. Evidence per row, the shared-item veto, Trash first, a journal of every removal, proof after removal, and saying what could not be read. |

## The window

Home, Apps (with Updates), Remnants, Background, Energy, Space, Developer and
Journal. Settings holds the rest.

- Home: what changed, and what needs the person.
- Apps: every installed app and its footprint, removal with a review panel,
  and Updates for apps Brim can update.
- Remnants: apps that have gone and left something, with Finish Removal,
  grouped selection and deletion, and items without a confirmed owner.
- Background: listed login items, launch jobs, extensions and firewall entries, by owner. Read gaps remain visible.
- Energy: what is using power now.
- Space: used, held by macOS and free, kept as three separate facts.
- Developer: tool caches, project build folders and update downloads, each
  with what clearing it costs.
- Journal: every removal, with put back where it can still work and a read-only Check removal action.

## Removal verification and release scope, 4 October 2026

Fresh registration observations are separate from bundle declarations and
command receipts. Results show remaining records, unknown locations,
surviving claims and recovery copies. Details carries icons, paths,
evidence and observation time. Cloud provider data remains excluded.

The common path stops and rechecks an exact launchd service before moving
its declaration, resets eligible privacy identifiers before code leaves,
and unregisters reviewed application paths. Installer records require a
full reviewed payload and independent helper qualification. Unsupported
foreign-app routes remain observational or manual.

See [the implementation and validation record](uninstall-registration-verification.md)
for shipped routes, withheld operations and actual machine checks.

Selected support/cache folders can contain separate helper apps. Their exact
application registrations are reviewed before removal, checked afterward,
and restored with identity checks when Undo is available. Embedded service
declarations remain available for runtime checks after their host moves;
automatic embedded service teardown is not qualified.

Background switches control execution, not erasure. Remaining login records
have conditional Open at Login instructions and a Settings link. Automatic
universal registration removal is not achieved, and neither Trash cleanup
nor a restart guarantees that every macOS-owned record disappears.

Universal erasure is deferred for this release. Broad database changes could
affect unrelated apps and add substantial compatibility and recovery work.
The priority is accurate attribution, dependable supported actions and clear
verification. Future selective adapters need proven ownership, authority and
lifecycle behavior. Known bugs in supported routes still need fixing;
deferral does not justify skipping discovery or hiding leftovers.

## Loading and review performance, 4 October 2026

Review planning uses ancestor lookups, ownership checks reuse one raw claim
read per bundle, and overlapping Apps and Updates loads share one inventory.
Independent footprint sizing has four workers; volumes appear before the
leftovers estimate finishes. Discovery coverage and fresh removal checks remain.
See [the measurements and limits](performance.md).
