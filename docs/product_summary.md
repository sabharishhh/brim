# Brim, in brief

Brim understands what software owns on your Mac, and gives you proof when
you remove it.

It is a native Mac utility with one main window. It builds an evidence-backed
record of each app's footprint, what it runs in the background, the space it
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
| Permissions | Asked once, during setup: Full Disk Access and the background helper. App Management is not asked for; see requirements.md. |
| Distribution | Direct download from GitHub Releases, signed with a free Apple Development certificate and not notarised. People open it once through Privacy & Security, Open Anyway. |
| Price | Free and open source for 1.0. Licence still to be chosen. |
| Quality bar | Wrong deletion is unacceptable. Evidence per row, the shared-item veto, Trash first, a journal of every removal, proof after removal, and saying what could not be read. |

## The window

Home, Apps (with Updates), Removed, Background, Energy, Space, Developer and
Journal. Settings holds the rest.

- Home: what changed, and what needs the person.
- Apps: every installed app and its footprint, removal with a review panel,
  and Updates for apps Brim can update.
- Removed: apps that have gone and left something, with Finish Removal, and
  a collapsed list of items nobody can be named for.
- Background: login items, launch jobs and extensions, by owner.
- Energy: what is using power now.
- Space: used, held by macOS and free, kept as three separate facts.
- Developer: tool caches, project build folders and update downloads, each
  with what clearing it costs.
- Journal: every removal, with put back where it can still work.
