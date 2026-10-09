# Brim

Brim shows what apps have left behind on your Mac, removes what you approve,
and then checks what is actually gone. Every item it lists says how Brim knows
who it belongs to, and anything another installed app still uses is left
alone.

## What it does

- **Remnants** finds files, settings and background jobs left by apps you
  have already removed.
- **Apps** lists everything installed and removes an app together with the
  files it keeps elsewhere on your Mac, in one review.
- **Background** shows login items and launch jobs, including those that
  point at software no longer installed.
- **Updates** finds new versions of your apps and installs one only when the
  same developer signed it.
- **Installers** can be opened in Brim first, to see what a package or disk
  image would add before anything changes.
- **Journal** records every removal and checks again that it stayed removed.
- **Space**, **Developer** and **Energy** show where your storage goes, which
  build caches can be cleared safely, and which apps are using power.

Removed items go to the Trash where possible, so most of them can be put
back. Anything that would be deleted permanently is shown before you approve
it.

## Installing

Brim needs macOS 27 or later.

1. Download `Brim-<version>.dmg` from
   [Releases](https://github.com/sabharishhh/brim/releases/latest) and drag
   Brim to Applications.
2. Open Brim. macOS says it cannot check Brim for malicious software. Choose
   **Done**.
3. Open **System Settings > Privacy & Security**, find the message about Brim
   under Security, and choose **Open Anyway**.

macOS asks this once because Brim is signed with a free Apple Development
certificate and is not notarised. To confirm that your download is the one
published, compare its checksum with the `.sha256` file beside it:

```bash
shasum -a 256 ~/Downloads/Brim-<version>.dmg
```

## Permissions

- **Full Disk Access** lets Brim read the folders where apps keep most of
  their data. Without it, Brim tells you what it could not read rather than
  reporting nothing.
- **An administrator password** is needed only when you approve the removal
  of protected items. Brim starts a temporary process for that batch and ends
  it when the work is done.
- **Touch ID or your password** confirms a removal that deletes something
  permanently.

Brim installs no background service and does nothing once it has quit.

## Privacy

Brim has no account, analytics or crash reporting. It goes online only to
check for updates: the App Store, Homebrew and each app's own update feed for
your apps, and GitHub for Brim itself. Feedback you send from Settings is
posted as a public GitHub issue containing your message, Brim's version, the
macOS version and the processor type.

## Building from source

You need Xcode 27 and an Apple ID signed in to Xcode.

```bash
git clone https://github.com/sabharishhh/brim.git
cd brim
xcodebuild -project Brim.xcodeproj -scheme brim -configuration Debug build
```

Brim and its administrator process check that both were signed by the same
team. To run a build signed by your own team, replace `9LY29YLFG2` in
`BrimCore/Sources/BrimPrivileged/HelperInterface.swift` with your team
identifier.

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md)
explains how to report a problem, run the tests and send a change.

## Licence

Brim is free software, released under the
[GNU General Public License, version 3](LICENSE) or any later version.
Copyright 2026 Sabharish.
