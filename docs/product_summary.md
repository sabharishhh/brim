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
| Network | Update checks and feedback the person explicitly sends. Reports go through Brim's relay and appear as public issues. |
| Permissions | Full Disk Access during setup. Protected cleanup shares administrator authentication for the selected batch, then the temporary process exits. No persistent background helper. Permanent user-level actions require a presence check; moving writable items to Trash needs no authentication. |
| Distribution | Direct download from GitHub Releases, signed with a free Apple Development certificate and not notarised. People open it once through Privacy & Security, Open Anyway. |
| Price | Free and open source for 1.0. Licence still to be chosen. |
| Quality bar | Wrong deletion is unacceptable. Evidence per row, the shared-item veto, Trash first, a journal of every removal, proof after removal, and saying what could not be read. |

## The window

Home, Apps (with Updates), Remnants, Background, Energy, Space, Developer and
Journal. Settings holds the rest.

- Home: storage, cleanup status and recently installed apps.
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
leftovers estimate finishes. Incomplete measurements display a lower bound or
Size unavailable in Space. Discovery coverage and fresh removal checks remain.
See [the measurements and limits](performance.md).

## Home summaries, 4 October 2026

Home groups Space and the four status cards together, followed by a full-width
Recently installed card and the app drop area. The Changes panel has been removed.
Recently installed shows current independent apps from the last five days,
including observed reinstalls. An update does not renew the installation date.
Entries expire while Home is open and refresh from current inventory when asked.
No installation watcher or resident service was added. App refresh no longer
loads the change history for a panel that does not exist.

Home checks recoverability on manual refresh as well as existing Trash and
activation events. A completed registration step counts as recoverable only
when its owned restore route survives. A stopped launch job also needs its
original declaration identity and modification time. Home calls registration
maintenance through the service protocol. A failed read cannot support a claim
that earlier removals can still be restored. Measured removed-app data is independent of unknown
protected storage; incomplete size reads remain visible in Remnants.

Home and Remnants use the same filter for unknown items worth reviewing. When
only those items remain, Home shows a review count rather than claiming Empty.
Saved installation history retains valid removal and reinstall cycles.

Verification: the final package suite passed with one existing skip. The signed
Release build and lint comparison passed. On the local machine, Home showed
a full-width recent-app row, no Changes panel and no stale restore banner after refresh.
Its ten unknown items matched the Remnants list. No new install or removal was
performed in the real account for this follow-up.

## Main consolidation, 4 October 2026

Cleanup, performance, Home and Settings feedback are combined with the current
build and release checks. Feedback preserves drafts and confirmed receipts;
sending is explicit and reports are public. Access settings retain the temporary
administrator flow, with no registered Brim background helper.

The combined strict package suite, signed Release build, signature checks,
12 script tests and 12 relay tests passed. The installed app opened Home,
Settings feedback and Access with the current permission wording. No report
was submitted and no removal was approved during consolidation.

The merge adds no lint findings relative to the reviewed UI branch. The full
comparison with older main still flags 560 style and complexity findings from
the accumulated UI changes, despite the total falling from 4,488 to 3,478.
These are not claimed to be resolved by this merge.

The consolidation CI runs exposed test assumptions that differed between the
local app and the runner. The embedded-component fixture now uses an identifier
path, rather than relying on inherited provenance to select a name-only folder.
Ownership assertions compare filesystem locations, and subprocess assertions
capture errno before assertion evaluation can change it. Shutdown uses its own
queue and its test waits asynchronously, retaining bounded-exit and single-exit
checks. The updated strict package suite and signed Release build passed locally.
