# Contributing to Brim

Thank you for your interest in Brim. Bug reports, fixes and improvements are
welcome. This guide explains how to report a problem, set up the project and
prepare a change for review.

## Scope

Brim does two things: it shows what software has left on a Mac, and it
confirms that those items are gone once they are removed. New features should
serve one of these purposes. Junk cleaning, system optimisation and duplicate
file finding are outside the project's scope. Please open an issue to discuss
a new feature before you start work on it.

Brim deletes files, so any change that affects what it offers for removal is
reviewed with particular care. Such a change is merged only when it is shown
to be safe, ideally with a test.

## Reporting a bug

Open an [issue](https://github.com/sabharishhh/brim/issues) and include:

- what you did, what you expected, and what happened instead;
- Brim's version, shown in About Brim, and your macOS version;
- if Brim offered to remove something it should not have, the item's path
  and the app Brim said it belonged to.

## Reporting a security problem

Please do not report a security vulnerability in a public issue. Use
**Report a vulnerability** on the repository's Security tab, which sends a
private report to the maintainer.

## Setting up

You need macOS 27 or later, Xcode 27 and an Apple ID signed in to Xcode.

```bash
git clone https://github.com/sabharishhh/brim.git
cd brim
xcodebuild -project Brim.xcodeproj -scheme brim -configuration Debug build
```

The app is built to
`~/Library/Developer/Xcode/DerivedData/Brim-<identifier>/Build/Products/Debug/brim.app`.
Open it from that path rather than by name, so that macOS does not start an
older copy.

Brim and its administrator process check that both were signed by the same
team. To test removals that need administrator access with your own signing
team, replace `9LY29YLFG2` in
`BrimCore/Sources/BrimPrivileged/HelperInterface.swift` with your team
identifier.

The project is laid out as follows:

- `Brim/` holds the app and its interface.
- `BrimCore/` is a Swift package. Detection lives in `BrimScan`, changes to
  the disk in `BrimOps`, and the rules both rely on in `BrimCore`.
- `Helper/` is the temporary administrator process.
- `scripts/` holds the release build and the lint check. The release
  steps are in [RELEASING.md](RELEASING.md).

## Making a change

1. Fork the repository and create a branch with a descriptive name, such as
   `fix/remnants-wrong-owner`.
2. Keep each pull request to a single change.
3. Add a test that fails without your change. If it guards against a real
   problem, describe that problem in the test's comment.
4. Run the checks below.
5. Open a pull request that explains the problem and how your change solves
   it.

## Checks

```bash
swift test --package-path BrimCore
python3 scripts/lint_changes.py --base origin/main
```

Continuous integration runs the same tests and lint, and builds the app with
strict concurrency checking. A pull request that adds lint or formatting
findings does not pass.

Tests that read or change the real Mac run only when `BRIM_REAL_ENV=1` is
set. Run them in a user account or virtual machine you can spare, never on
data you would mind losing.

## Code and writing

- Every item Brim offers for removal must say how Brim knows who it belongs
  to. A location that could not be read is reported as unread, never treated
  as empty.
- Text that people read in the app should be short, plain and formal. Please
  do not use em dashes or en dashes.
- Commit messages should explain the problem and the result in full
  sentences.

## Conduct

Please keep issues and reviews respectful and on topic.

## Licence

By contributing, you agree that your contributions are licensed under the
[GNU General Public License, version 3](LICENSE) or any later version, the
same licence as Brim.
