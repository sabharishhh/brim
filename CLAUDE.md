# Working on Brim

Brim tells people what software has left on their Mac and proves it is gone
when they remove it. Everything below exists because getting one of these
wrong cost real time in a previous session.

## How to work here

**Run it before you believe it.** Every serious bug in this project was
found by opening the app or the real filesystem, and every one of them
passed its unit tests first. Full Disk Access silently under-reporting,
Safari missing from the inventory, three false positives in the BTM parser,
eight stale Launch Services records behind a screen that said "nothing
remains", macOS group containers offered up for deletion. Reading the code
would not have caught any of them. Build, launch, look, then say what you
saw.

**Say what you actually verified.** "Tests pass" and "I watched it work" are
different claims. If something was not checked, say so in the same sentence
rather than leaving it implied.

**Be wrong out loud.** Several times a confident diagnosis here was wrong:
that Full Disk Access was not needed, then that it was not the blocker, then
that root would override a data vault. Each correction was cheap. Each one
defended would have been expensive. When a test or the user contradicts you,
lead with the correction and move on. Do not re-explain the mistake.

**Finish the sequence.** When several pieces of work are agreed, do them all
and report at the end. Do not stop after each one to ask whether to
continue.

**Ask before destroying anything**, including deleting files that look like
dead code. Everything else, just do.

## Testing

Test the defect, not the surface. A test earns its place by failing against
the old behaviour, and the best ones in this repo name the incident in their
comment so the next person knows what they are protecting.

Real environment tests live behind `BRIM_REAL_ENV=1`. They touch the actual
machine, so the harness must leave nothing behind. It has failed at this
twice: four sandbox containers that cannot be removed by anyone, and 58
bundles left in the Trash with 58 Launch Services records to match.

Do not run the whole suite after every edit. Run what you changed, and the
full suite before committing.

## Product rules

**Evidence, never assertion.** Every row a user might act on says how Brim
knows. "Orphaned" is a claim and has to name the record that orphaned it.

**"Did not look" is not "nothing found."** Any surface that could not be
read reports that it could not be read. `RegistrationCoverage` and
`Capability` exist for this. A zero that was never measured is a lie.

**Group by what the user reasons about.** They think about an application,
not a directory. Two rows for `Application Support/Codex` and
`Caches/Codex` is a failure of the list, not of the user.

**Interrupt for irreversible things only.** Moving something to the Trash
needs no fingerprint. Permanently deleting something that matters gets one
prompt for the whole plan, and a five minute grace window after it. The
failure to avoid is not an unauthorised deletion, it is a user who has been
asked so often that they stop reading.

**Never collapse numbers that mean different things.** Free space, space
macOS is holding, and space Brim could clear are three facts. One combined
figure is how cleaning utilities end up lying.

**No AI written explanations.** `C-4` cut them from V1 because they are
presentation over facts the deterministic renderer already produces. If a
row is unclear, the usual cause is missing structure, not missing prose.

## Writing

Text a person reads should sound like someone who knows the software
explaining it, not like a model describing it.

- **No em dashes or en dashes anywhere.** Break the sentence, use a comma,
  or use a colon. `UserFacingCopyTests` enforces this for the model layer.
- Vary sentence shape. Three sentences of identical rhythm reads as
  generated even when every word is right.
- Say the consequence, not the category. "Gone once you empty the Trash"
  beats "Non recoverable".
- Authentication reasons are rendered by macOS as "Brim is trying to ___",
  so they are lower case verb phrases with no full stop.
- `ByteText`, not `ByteCountFormatter`. The latter writes "Zero KB".

## Commits

Author is the user alone. No co-author trailers, no tool attribution.

Write the body as prose explaining why the change exists and what it cost to
find. A commit here should still make sense to someone who never saw the
conversation. Split unrelated changes rather than staging everything.

## macOS facts learned the hard way

- **TCC is judged on the responsible application, not the effective user.**
  `sudo` does not grant Full Disk Access. A root shell launched from a
  terminal without it is still a process without it.
- **Container metadata is a data vault.** `~/Library/Containers/<id>` gets a
  `containermanagerd` metadata file that neither Full Disk Access nor root
  can unlink. Only Finder or the owning daemon can. Never create one in a
  test.
- **`sfltool dumpbtm` raises an administrator prompt.** Never call it during
  a scan. `BackgroundItemSurface` defaults to `.onlyWhenAsked` for this
  reason.
- **`tccutil` resolves through Launch Services**, so privacy grants must be
  cleared while the bundle still exists. Hence `ExecutionPhase.privacyReset`
  running first.
- **Deleting a bundle does not unregister it.** Launch Services keeps the
  record, which is why removed apps linger in "Open With". Retract it after
  removal, and expect the daemon to re-register a bundle that is still in
  the Trash, which is correct rather than stale.
- **`contentsOfDirectory(at:)` drops Safari**, because it skips the Cryptex
  symlink. Use the path based variant and resolve symlinks afterwards.
- **`NSWorkspace.icon(forFile:)` is the only correct way to get an app
  icon.** Size it before caching or the window server scales a 512pt bitmap
  into a 28pt row every frame.
- **Nested `ObservableObject`s do not propagate.** Observing a container
  whose properties are other models gets no updates. Observe each model
  directly.
- **`NavigationLink(value:)` inside `List(selection:)` breaks
  accessibility.** Rows expose as `AXUnknown` and ignore a press. Use
  `.tag`.
- **Section minimum widths ratchet the window.** A split view asking for
  more than the window has grows it, `NSSplitView Subview Frames` saves the
  new size, and nothing shrinks it back.

## Build and run

```bash
xcodebuild -project Brim.xcodeproj -scheme brim -configuration Debug build
swift test --package-path BrimCore
BRIM_REAL_ENV=1 swift test --package-path BrimCore   # touches the real machine
```

Sandboxed shells cannot run `xcodebuild` or `swift`. Use
`dangerouslyDisableSandbox` for those two commands only.

The app is at
`~/Library/Developer/Xcode/DerivedData/Brim-*/Build/Products/Debug/brim.app`.
Launch it by path. Never by bundle identifier, because Launch Services has
resolved that to a stale build before now.

Docs live in `docs/` and are gitignored. `implementation_plan.md` holds the
task numbering, the frozen step vocabulary in §3.1, and the acceptance
criteria. Read it before adding a step kind.
