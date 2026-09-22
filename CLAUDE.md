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

`FileManager.trashItem` always means the real Trash, which is why the plain
suite was filling it. Under XCTest, `SafeOps.trashItem` diverts to a
per-process directory in `NSTemporaryDirectory`, detected rather than
configured so no test has to opt in, and compiled out of a release build.
A full run now adds nothing to `~/.Trash`; check that it still does not.

Do not run the whole suite after every edit. Run what you changed, and the
full suite before committing.

## Product rules

**Two things, done properly.** Brim tells people what software has left on
their Mac and proves it is gone when they remove it. Everything else in the
app earns its place by serving one of those or it does not ship. A duplicate
file finder, a command line tool, an MCP server and a machine-wide
Background Task Management reset were all built and all removed, not because
any of them was broken but because none of them was this. The failure mode
for a utility is not missing a feature, it is becoming the kind of cleaning
app whose feature list is its argument.

**Evidence, never assertion.** Every row a user might act on says how Brim
knows. "Orphaned" is a claim and has to name the record that orphaned it.

**"Did not look" is not "nothing found."** Any surface that could not be
read reports that it could not be read. `RegistrationCoverage` and
`Capability` exist for this. A zero that was never measured is a lie.

**Group by what the user reasons about.** They think about an application,
not a directory. Two rows for `Application Support/Codex` and
`Caches/Codex` is a failure of the list, not of the user.

**Ask once, at the start.** Everything Brim needs from the person is
settled during setup, while they are paying attention to setup. A
permission dialog standing between someone and a list they asked to see
is a bug, and the fix is usually to find the free way to read the same
thing.

**Approval comes from a person, in Brim's window, or not at all.**
`requestApproval` returns a receipt and cannot approve anything. The only
mint is `BrimService.grantApproval`, reached through `ApprovalGranting`,
which is not on `BrimServiceProtocol` and has no XPC message, so nothing
reaching Brim from outside its own process has a method to call rather
than a check to argue with. Brim shipped a command line tool and an MCP
server once; they are gone, and this rule is why neither could ever have
approved anything.
A service only mints if a `ConsentSource` was installed in its own
process, which the app does and nothing else does. Tokens live in memory
for five minutes: two processes cannot share one, and that is the point.
`ApprovalGateTests` holds every part of this, including a grep test that
fails if a second function ever returns an `ApprovalToken`.

**Both ends of a connection prove who they are.** Brim is
`com.sabharishhh.brim`, team `9LY29YLFG2`, and `MutualAuthentication` is
the only place that decides what that means. The listener pins the app,
the client pins the service, and a connection that cannot be pinned is
not made. There is no boolean to switch it off: a caller either names one
of Brim's signed components or names the anonymous same-process case out
loud, and `XPCAuthenticationTests` fails if a third option appears.

**Interrupt for irreversible things only.** Moving something to the Trash
needs no fingerprint. Permanently deleting something that matters gets one
prompt for the whole plan, and a five minute grace window after it. The
failure to avoid is not an unauthorised deletion, it is a user who has been
asked so often that they stop reading.

**Tier S is Shared, and it is a veto.** A, B and C are one scale, how
sure Brim is. S is not on it: it means something else installed on this
Mac claims the item, so the item leaves the selection and cannot re-enter
it. The code used to read S as "cryptographically guaranteed" and select
it, so anybody following the specification and writing `tier: .S` to
protect a shared component would have marked it for removal.
`TierSVetoTests` holds the one-way rule.

**Never collapse numbers that mean different things.** Free space, space
macOS is holding, and space Brim could clear are three facts. One combined
figure is how cleaning utilities end up lying.

**A step kind that nothing emits is decoration.** Four of the eleven in
§3.1 were declared, reserved and dead: a plan containing one recorded
`unsupported_kind`. `StepVocabularyTests` reads the planner and the
executor and fails when a kind has no producer or no branch.

**History is snapshots and subtraction, never a watcher.** Each
enumeration appends one observation per application and nothing is ever
overwritten, so "what changed" is the last two snapshots differenced. A
resident process noticing installations is what every competitor ships
and what nobody wants: battery, permissions, and one more daemon on a
Mac whose complaint is that it has too many. One snapshot means there is
nothing to compare against, which is not the same as nothing changing,
and the copy says which it is.

**A location needs a rule, not just a path.** `LocationInventory` pairs
every place software hides with how a match there is proved, and the
rule decides the tier: an identifier match is Tier B, a name match is
Tier C, and a domain that can only ever be name-matched floors the tier
whatever the row says. Adding a path without deciding its rule is how a
cleaner deletes a folder for sharing a word with your app.

**An unfinished search selects nothing.** A footprint is a claim about
what is on the disk, and a scan that timed out or could not read
somewhere cannot support it. Everything found is still shown and every
row can still be ticked by hand; what goes away is Brim ticking them for
you. `ScanBudget` gives the run a deadline so one unreadable path cannot
hang it, and `ScanCompleteness` carries the gap all the way to the row.

**The veto applies to registrations, not only to files.** A suite
installs one login-item helper and several applications register against
it. The file veto never sees that, because a registration is a record in
a database with no file to veto, so `owned(by:...)` takes a claimant list
and drops anything a surviving application also claims. One way only, as
Tier S is.

**Never run a vendor's uninstaller.** Find it, reveal it in Finder, and
let the person decide. Detection is deliberately shallow and matches
whole words in the file name: a deep search finds every framework
shipping a string with "uninstall" in it, and a false positive here tells
somebody to run a stranger's executable.

**Three classes of developer artefact, and the third is untouchable.**
Regenerable caches Brim removes itself. Tool managed stores are delegated
to the tool's own command, shown in full before approval, because deleting
a module cache by hand leaves the tool confused. Stateful artefacts are
reported and routed, never touched: Xcode archives, simulator devices and
container disk images are always in this class whatever their size, and
`DeveloperSafetyTests` holds the line.

**Savings are what comes back, not what was counted.** Two identical files
on APFS often share their blocks already, so removing one frees nothing.
Snapshots pin blocks the same way, which is why a deletion can free
nothing at all and has to say so rather than report success.

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
- **`sfltool dumpbtm` raises an administrator prompt, and nothing needs it.**
  The prompt belongs to the tool, not to the data. Background Task
  Management lives in `/var/db/com.apple.backgroundtaskmanagement` as mode
  644 `NSKeyedArchiver` archives, one per account, named after the directory
  UUID `mbr_uid_to_uuid` returns. Reading them needs Full Disk Access and
  nothing else. `BTMStore` does that; never reach for the tool again.
- **Nothing third party can make macOS tidy its background list.** The
  collection pass that drops records for deleted apps runs when a client
  reaches `BTMManagerService`, and that listener refuses anyone without
  `com.apple.private.backgroundtaskmanagement.manage`. `sfltool` gets in
  because Apple signs it with that entitlement. Root does not help: an
  entitlement comes from the signature, not the user, the same way TCC is
  judged on the responsible application. Every public `SMAppService` call
  reaches the daemon by another route that does not collect. Opening
  Login Items in System Settings does collect, because System Settings is
  entitled.
- **Old BTM versions stay on disk.** A `BackgroundItems-v16.btm` from a
  previous macOS still sits beside the v18 files, listing software that has
  since been removed. Read the highest version only, or invent leftovers.
- **`setCodeSigningRequirement` returns nothing and raises on a string it
  cannot parse.** So an unparseable requirement is a crash, not a refusal,
  and there is no return value to check. Compile it with
  `SecRequirementCreateWithString` first and refuse the connection if it
  will not compile.
- **One requirement covers development and Developer ID.** `anchor apple
  generic` with the team in `certificate leaf[subject.OU]` is satisfied by
  an Apple Development certificate and by Developer ID alike, so there is
  no looser development string that could be left switched on in a shipped
  build. Verify a requirement against a real binary with
  `codesign --verify -R=<requirement>`; it is faster than reasoning about
  it and it caught that the old string rejected Brim's own app.
- **`LAContext` in a unit test raises a real dialog and hangs the suite.**
  Presence goes through the injected `PresenceCheck` so tests can reach
  the approval gate without one. Killing a run mid-prompt leaves
  `System authentication is running` behind for the next one.
- **A running application undoes a removal.** It keeps its state in
  memory and writes it back when it quits, so preferences and caches
  removed underneath it reappear minutes later and the removal looks as
  though it silently failed. `apply` refuses before the token is spent,
  so quitting and asking again is the whole remedy. Helpers inside the
  bundle count: they have their own identifiers and write just as much.
- **Order snapshots by rowid, not by timestamp.** Two scans a second
  apart share a stored `observed_at` at SQLite's resolution, and ordering
  on it picks between them arbitrarily: growth came back inverted and the
  comparison ran against the wrong snapshot. Both tests passed when run
  filtered and failed in the full suite, which is what a timing-dependent
  bug looks like.
- **`kMDItemLastUsedDate` earlier than `kMDItemDateAdded` is the
  migration signature.** It can only happen when the usage record
  travelled with the bundle and nobody has opened it since. Sharper than
  comparing against the system install date, which catches almost nothing
  on a restored Mac. Real example here: IINA arrived 14 September, last
  opened 7 August.
- **`~/Library/Preferences/ByHost` is a second copy of the settings.**
  A scan of `Preferences` walks straight past it. Real examples on this
  Mac: Claude and VS Code both keep a `ShipIt` domain there.
- **An audio plug-in's file name says nothing.** `Reverb.component` is
  attributable only by reading the bundle's own `Info.plist`, which is
  why every path-matching scanner misses them. The same is true of
  preference panes, Quick Look generators and the rest of that family.
- **The Darwin per-user folders hold real data and nothing enumerates
  them.** `confstr(_CS_DARWIN_USER_CACHE_DIR)`, not a hard-coded path,
  and under a fixture root it must answer inside the tree or a test
  walks the developer's own cache. WhatsApp keeps 6 MB there.
- **`cfprefsd` owns preferences, not the file.** Unlinking a plist and
  leaving the daemon holding the domain means it writes the file straight
  back out, and the person watches a setting they removed reappear. Clear
  the domain through `CFPreferencesSetMultiple` first, in both host
  scopes, then trash the file. Never `.GlobalPreferences`.
- **`pluginkit -m -v` prints `((null))` for a missing version.** Finding
  the version by the last opening bracket splits the identifier in the
  wrong place; balance from the end. Its paths contain spaces and
  non-ASCII, so the path is everything after the third tab and never the
  last whitespace-separated field, and the listing ends with a count line
  that is not an extension.
- **Two immutable flags, and they are not interchangeable.**
  `UF_IMMUTABLE` is Finder's "Locked" and the owner can clear it.
  `SF_IMMUTABLE` needs root and SIP's permission, and is reported rather
  than offered. `SafetyChecker` used to refuse both silently, so a locked
  file went missing from the plan instead of explaining itself.
- **`pkgutil --forget` deletes nothing.** It removes the installer's
  record, which is why a product keeps appearing in `pkgutil --pkgs` and
  why an installer can offer to "repair" something already removed. The
  record cannot be rebuilt, and Apple's are never forgotten: a missing
  system receipt can leave a later macOS update unable to reason about
  what is installed.
- **Detection in `BrimCore`, mutation in `BrimOps`.** `BrimCore` depends
  on nothing and the planner has to be able to ask whether a file is
  locked or whether a bundle ships an uninstaller. Where a fact is
  therefore read in two modules, a test holds the two readings to one
  answer.
- **Brim is `com.sabharishhh.brim`.** Nothing should carry a list of
  identifiers for it: `SafetyChecker` reads its own from the bundle it was
  given, because the hardcoded list named `com.google.Brim` and a
  `devplaceholder` identifier and matched neither the real application nor
  anything else, so self-removal was silently blocked. The two old
  identifiers are kept only so an upgrade can clear what they left.
- **An `SMAppService` daemon survives an application update.** The root
  process answering can be the one an older Brim registered, running that
  version's rules about what is safe to remove. Check the version on
  connect and replace a daemon you do not recognise. Bump
  `BrimJobHelper.version` whenever the interface changes, or an older
  daemon hangs on a selector it does not implement.
- **Only root can clear the quarantine.** `/Library/Application
  Support/Brim/Set aside` is root owned, so `SMAppService.unregister`
  first and the folder is there for good. The daemon clears it through
  `uninstallSelf` while it is still running, and only then is it
  unregistered.
- **A Swift error loses its sentence crossing XPC.** `localizedDescription`
  is computed, so bridging an error to `NSError` and replying with it
  arrives as `Code=0 "(null)"`. `BrimXPCServer.wire` pins the sentence into
  the user info first. A refusal that says nothing gets read as a bug and
  worked around.
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
- **A composed row needs a role as well as a label.**
  `.accessibilityElement(children: .ignore)` with a label but no trait
  exposes as `AXUnknown`, the same dead end as the sidebar rows. Add
  `.isStaticText`, or `.isButton` with an `.accessibilityAction` when the
  row does something.
- **`Toggle("")` exposes nothing to press.** Give it a real label and
  `.labelsHidden()`. Hidden is not the same as absent.
- **`.textSelection(.enabled)` adds a child text element**, so the string
  is in the tree twice and a reader says it twice. Composing the row with
  `children: .ignore` removes the duplicate.
- **Check the tree, not the automation tool.** `scripts/ax_tree.swift`
  dumps the real one. A tool that walks a few levels reported seventeen
  elements for a window that actually had seventy-seven, and the app was
  blamed for what the tool could not reach.
- **Section minimum widths ratchet the window.** A split view asking for
  more than the window has grows it, `NSSplitView Subview Frames` saves the
  new size, and nothing shrinks it back.
- **A greedy `NSViewRepresentable` overrides `.defaultSize` silently.** A
  hosted `NSTableView` made the window open at half the display width no
  matter what the scene asked for, and clearing every piece of saved state
  made no difference. If a window ignores its default size, suspect a
  hosted AppKit view before suspecting restoration.
- **An ideal size on the root view is measured, and measuring it walks
  everything.** `.frame(idealWidth:idealHeight:)` on the content of a
  `WindowGroup` makes SwiftUI size the entire tree to answer, and hand that
  to AppKit as an intrinsic size, so every scroll in every panel ran a
  window-wide constraint solve. Profiling put 43% of the main thread in
  `GraphHost.flushTransactions`, 25% in `-[NSWindow layoutIfNeeded]` and
  14% in `ViewGraphRootValueUpdater._sizeThatFits`, with no Brim frames on
  the stack at all: nothing was re-running, everything was being
  re-measured. `.defaultSize` on the scene sets the opening size without
  any of that. A minimum is a constant and costs nothing.
- **`ScrollView { VStack }` proposes a nil height.** So the stack works out
  its ideal height and every `.fixedSize(horizontal: false, vertical: true)`
  inside re-measures its text to answer, on every pass. A `List` measures a
  row once and caches it.
- **`.accessibilityElement(children: .combine)` costs more than the
  children.** Combining walks and merges every child element. Where a row
  carries a written `.accessibilityLabel`, `.ignore` does less and says the
  same thing.
- **Formatters belong outside the body.** `Text(date, format: .dateTime…)`
  builds a `Date.FormatStyle` every time the row draws, and
  `RelativeDateTimeFormatter()` is expensive to construct. Thirty-nine
  history rows formatting a date per frame is what made that list heavy.
  Format once, when the value is made.

## Build and run

There is no `timeout` on this machine, so a command that wraps the suite
in one silently does nothing and looks like a pass. Run long things in the
background and wait on the process instead.

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
