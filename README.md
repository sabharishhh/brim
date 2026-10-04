# Brim

Brim shows what software has left on your Mac, removes approved items,
and checks what is gone, what remains and what could not be checked.

Every row says how Brim knows what it claims: an installer receipt, a
launch job, a record macOS keeps, a matching identifier. Anything another
installed app still uses stays where it is. Removals go to the Trash first
when possible. Writable files can be put back from History. Protected files
may be retained as recovery copies without a restore action in Brim.
Permanent actions, including deleting recovery copies, are shown before
approval.

Brim runs on macOS 27 or later.

## Installing

1. Download `Brim-<version>.dmg` from
   [Releases](https://github.com/sabharishhh/brim/releases/latest) and drag
   Brim to Applications.
2. Open Brim. macOS says it cannot check it for malicious software and
   offers only Done or Move to Trash. Choose **Done**.
3. Open **System Settings, Privacy & Security**, scroll to Security, and
   choose **Open Anyway** beside the line about Brim. Confirm with your
   password or Touch ID.
4. Brim opens. From then on it opens normally.

macOS asks this because Brim is signed with a free Apple Development
certificate and not notarised by Apple, which needs a paid developer
account. The signature is still checked: Brim and its temporary administrator
process verify each other as Brim components signed by the same team
(`9LY29YLFG2`). You can check the
download against the `.sha256` file published beside it:

```bash
shasum -a 256 ~/Downloads/Brim-1.0.dmg
```

### What Brim asks for

Brim asks for Full Disk Access during setup. Protected cleanup needs
administrator authentication when you approve it.

- **Full Disk Access.** Much of what apps leave behind sits in places macOS
  only lets an app with this permission read. Without it Brim says what it
  could not read rather than reporting nothing.
- **An administrator password** for a selected batch of protected cleanup.
  Brim starts a temporary administrator process, checks each item, and ends
  the process when the operation finishes. It does not install a background
  job or run after Brim quits. Reading protected recovery copies also needs
  explicit authorization.
- **Touch ID or your password** once per removal that deletes anything
  permanently. Administrator authentication covers this check for protected
  cleanup, so the batch does not need a second prompt. Moving writable items
  to the Trash needs no authentication.

### Checking a removal

The result shows files confirmed gone, registrations still listed and
locations Brim could not check. A completed command and an empty
registration list are reported separately. Shared items and recovery copies
stay identified in the result.

Use **Check removal** from a removal's context menu in Journal to read its
current state again. This records another observation without removing
anything. Some records can be removed only by their owning app or a specific Settings
control. Background activity switches do not erase registrations. Brim keeps
remaining records visible rather than claiming they have gone.

### Deep uninstall scope

Brim traces associated files and components, protects shared items, and
removes approved items through supported cleanup routes. Exact application
registrations and supported launch jobs are checked again after removal.
Remnants supports selected and grouped removal; protected cleanup shares
temporary administrator access for the selected batch.

This does not remove every registration or permission entry for every app.
Some records are shared, controlled by macOS or removable only by their
owner. Brim reports those limits and provides a manual route where one is
available. Emptying Trash or restarting does not guarantee their removal.

Universal removal is deferred for this release. Forcing the last records
out through shared databases or broad resets could affect other apps and
would add substantial compatibility and recovery work. The priority is
reliable detection, removal and verification on supported routes.
See [achievements, limits and future work](docs/uninstall-registration-verification.md#release-scope-4-october-2026).

## Privacy

Brim works on your Mac and has no account, analytics or crash reporting.
It goes online to check for updates and when you send feedback:

- **Your apps.** Updates asks the App Store (`itunes.apple.com`,
  `apps.apple.com`) about apps installed from it, Homebrew
  (`formulae.brew.sh`) about apps installed with it, and each other app's
  own update feed, the one it already checks itself. These requests carry
  the app's identifier or name.
- **Brim itself.** Brim asks GitHub for the latest release to tell you when
  a new version is out.
- **Feedback.** Reports you send from Settings become public GitHub issues
  through Brim's feedback service. They include your text, Brim's version and
  build, the macOS version and processor type.

## Loading and review performance

Brim shares overlapping application reads, reuses ownership claims within a
review, and bounds independent measurements to four workers. Later checks
still read current disk state. See [measurements and remaining work](docs/performance.md).

## Home summaries

Home shows storage and cleanup summaries, followed by currently installed apps
that arrived in the last five days. An observed removal clears
the recent entry; an observed reinstall starts a new five-day period. Brim
compares its own scans, so activity between scans may not be recorded.

Check Again also checks which removals still have files in Trash. The Remnants
card measures data belonging to removed apps separately from unknown storage.
Unreadable locations remain identified in Remnants without asking for
administrator access merely to open Home.

## Building from source

You need Xcode 27 and a free Apple ID signed in to Xcode.

```bash
git clone https://github.com/sabharishhh/brim.git
```

```bash
cd brim && xcodebuild -project Brim.xcodeproj -scheme brim -configuration Debug build
```

The app lands in
`~/Library/Developer/Xcode/DerivedData/Brim-*/Build/Products/Debug/brim.app`.
Open it by path.

Brim pins its own team identifier when the app and its administrator process
connect, so both components must be signed by your team. Replace
`9LY29YLFG2` in `MutualAuthentication.swift` and `HelperInterface.swift`
with your own team to run your build end to end.

To make a disk image:

```bash
./scripts/build_release.sh
```

It signs with the first Developer ID or Apple Development certificate in
your keychain, and notarises only when `APPLE_ID`,
`APPLE_APP_SPECIFIC_PASSWORD` and `APPLE_TEAM_ID` are set.

### Tests

```bash
swift test --package-path BrimCore
```

Tests that touch the real machine run only with `BRIM_REAL_ENV=1`.

## Layout

- `Brim/`: the app.
- `BrimCore/`: the engine, as a Swift package. Detection in `BrimScan`,
  changes to the disk in `BrimOps`, and the checks everything passes
  through in `BrimCore`.
- `Helper/`: the temporary administrator process.
- `scripts/`: release build and coverage tools.

## Reporting a problem

Open an [issue](https://github.com/sabharishhh/brim/issues). If Brim
offered to remove something it should not have, say what the item was and
which app Brim said it belonged to.
