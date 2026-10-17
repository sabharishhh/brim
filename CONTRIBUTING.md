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

Please do not report a security vulnerability in a public issue. See
[SECURITY.md](SECURITY.md) for how to report one privately.

## Setting up

You need macOS 27 or later, Xcode 27 and an Apple ID signed in to Xcode.

```bash
git clone https://github.com/sabharishhh/brim.git
cd brim
make run
```

`make run` builds the app and opens that build by its path, so macOS does
not start an older copy. `make build`, `make test` and `make lint` run the
steps on their own.

Brim and its administrator process check that both were signed by the same
team. To test removals that need administrator access with your own signing
team, replace `9LY29YLFG2` in
`BrimCore/Sources/BrimPrivileged/HelperInterface.swift` with your team
identifier.

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the project is laid out,
what each module does and where to start for common changes.

## Making a change

1. Fork the repository and create a branch with a descriptive name, such as
   `fix/remnants-wrong-owner`.
2. Keep each pull request to a single change.
3. Add a test that fails without your change. If it guards against a real
   problem, describe that problem in the test's comment.
4. Run the checks below.
5. Open a pull request as described under [Pull requests](#pull-requests).

## Checks

```bash
make test
make lint
```

Continuous integration runs the same tests and lint, and builds the app with
strict concurrency checking. A pull request that adds lint or formatting
findings does not pass.

Tests that read or change the real Mac run only with `make test-real`,
which sets `BRIM_REAL_ENV=1`. Run them in a user account or virtual machine you can spare, never on
data you would mind losing.

## Code and writing

- Every item Brim offers for removal must say how Brim knows who it belongs
  to. A location that could not be read is reported as unread, never treated
  as empty.
- Text that people read in the app should be short, plain and formal. Please
  do not use em dashes or en dashes.

## Commit messages

Write the subject as an instruction that completes "This commit will ...":
`Keep a surviving copy's data when removing an app`, not `Fixed data bug` or
`fix(uninstall): data`. Start with a capital letter, leave off the full stop,
and keep it under 72 characters. Brim does not use type prefixes or ticket
numbers.

Leave a blank line, then explain in plain sentences, wrapped at 72
characters, what was wrong, how you found it and what changes as a result.
Someone reading the history a year from now should understand the commit
without the pull request. If you could not check something, say so.

Keep each commit to one change. Add a `Co-authored-by` line only for a person
who wrote part of it.

## Pull requests

Give a pull request a title written like a commit subject. In the
description, say what the problem was, what the change does, and how you
tested it, including anything you did not test. A few short paragraphs are
enough; the pull request template only reminds you of these.

## Conduct

Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Licence

By contributing, you agree that your contributions are licensed under the
[GNU General Public License, version 3](LICENSE) or any later version, the
same licence as Brim.
