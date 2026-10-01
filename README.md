# Brim

Brim is a local-first macOS utility designed to completely uninstall applications by scanning the filesystem for associated footprints (evidence) and removing them.

## Architecture & Invariants

Brim is engineered for maximum security and testability. It strictly adheres to several invariant rules:

1. **No Absolute Paths**: All file operations are resolved relative to an injected `FileSystemRoot`. There are no `"/Library"` or `"~/Library"` string literals in the core engine. This allows the engine to be tested against a purely synthetic filesystem.
2. **Strict Safety Gates**: The `SafetyChecker` statically rejects attempts to uninstall protected locations, such as `/System`, iCloud `Mobile Documents`, the Brim app itself, or immutable files.
3. **Core Isolation**: The business logic (`BrimCore`) is decoupled from the UI. It runs as a pure Swift package.
4. **Approval Required**: No deletion can occur without a cryptographic execution token minted in Brim's own window. A process holding a service object but no window has no route to one, which is an absence of the machinery rather than a check it might pass. The token is bound to a hash of one specific plan, so an approval cannot be replayed against a different set of targets.
5. **Honest Accounting**: Recreatable data (caches, temporary files) is deleted outright so the reclaimed space is real; anything holding settings or user data is moved to the Trash and can be restored from History. The two totals are reported separately rather than as one figure.

## Requirements

Brim requires **Full Disk Access** (System Settings › Privacy & Security ›
Full Disk Access), and must be reopened after it is granted. Without it Brim
cannot read the protected locations where an application's footprint lives,
so its results are incomplete rather than merely slower. A plan that
permanently deletes anything requires Touch ID or password authentication
once for the whole selection.
Moving items to the Trash asks for no authentication.

## Building and testing

Build the app with Xcode 27:

```bash
xcodebuild -project Brim.xcodeproj -scheme brim -configuration Debug build
```

Run the package tests:

```bash
swift test --package-path BrimCore
```

Real environment tests are opt-in with `BRIM_REAL_ENV=1` and touch the actual
machine. The ordinary suite uses fixtures.

## Project Structure

* **`Brim.xcodeproj`**: The main macOS application project containing the UI, XPC Service, and Privileged Helper.
* **`BrimCore/`**: The local Swift package containing the backend engine, scanners, and tests.
* **`Helper/`**: The privileged daemon entry point and launchd configuration.
* **`scripts/`**: Release packaging, lint checks, and accessibility inspection.

Local plans, agent instructions, dependency caches, generated output, and
personal Xcode settings are excluded from Git. The native app is the only
product in this repository. Swift package lockfiles remain tracked for
reproducible builds.


## Releases

Signing stays on the maintainer's Mac. GitHub Actions checks the tagged code
and signed package before publishing a draft release.

Start from a clean commit on main, with Xcode 27 and an Apple Development or
Developer ID certificate in your keychain:

```bash
./scripts/build_release.sh
```

The script builds only committed files and records the source commit inside
the signed app. It checks the app and helper signatures and writes a DMG and
a portable SHA-256 checksum to `build/`. A free Apple Development certificate
works; without notarisation, people open the download through Privacy &
Security, Open Anyway. Developer ID builds can be notarised when `APPLE_ID`,
`APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` are set.

For version 1.0, create the tag and attach the package to a draft:

```bash
git tag v1.0
git push origin v1.0
gh release create v1.0 build/Brim-1.0.dmg build/Brim-1.0.dmg.sha256 \
  --draft --verify-tag --title "Brim 1.0" --generate-notes
gh workflow run release.yml -f tag=v1.0
```

Use the project's version for the tag and filenames. The workflow runs the
same build, test, and lint checks as a PR. It publishes only after verifying
the checksum, signatures, helper layout, version, and source commit. No
signing certificate or Apple password is stored in GitHub.
