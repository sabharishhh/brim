# Brim

Brim shows what software has left on your Mac, and proves it is gone when
you remove it.

Every row says how Brim knows what it claims: an installer receipt, a
launch job, a record macOS keeps, a matching identifier. Anything another
installed app still uses stays where it is. Removals go to the Trash first
and can be put back from History.

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
account. The signature is still checked: Brim and its helper refuse to talk
to anything not signed by the same team (`9LY29YLFG2`). You can check the
download against the `.sha256` file published beside it:

```bash
shasum -a 256 ~/Downloads/Brim-1.0.dmg
```

### What Brim asks for

Brim asks once, during setup.

- **Full Disk Access.** Much of what apps leave behind sits in places macOS
  only lets an app with this permission read. Without it Brim says what it
  could not read rather than reporting nothing.
- **Its helper.** A small background job, approved in System Settings,
  Login Items, that removes the few things only an administrator can:
  launch jobs and files an installer put in `/Library`. It checks each item
  itself and never takes a path from the app.
- **Touch ID or your password** once per removal that deletes anything
  permanently. Moving things to the Trash needs nothing.

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

Brim pins its own team identifier when the app and its helper connect, so
a build signed with another team will not reach its helper. Replace
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
- `Helper/`: the administrator helper.
- `scripts/`: release build and coverage tools.

## Reporting a problem

Open an [issue](https://github.com/sabharishhh/brim/issues). If Brim
offered to remove something it should not have, say what the item was and
which app Brim said it belonged to.
