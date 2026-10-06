# Experience implementation

## First slice, 4 October 2026

Home now puts app inspection before its summaries. The native chooser starts in
Applications and opens the selected app through the existing inspection route.
Cancellation leaves Home unchanged. Dragging remains available. The sidebar uses
Brim's bundled character icon beside its name; the standalone cutout assets from
the design research are no longer present in the branding directory.

The solid inspection button has a local pointer-driven edge light and a shallow
press response on its background. Its label, focus indication and hit region
stay stationary. It has no timer, global pointer listener or repeating animation.
Tracking stops for disabled controls, inactive windows, drag targeting, reduced
motion, reduced transparency and increased contrast. Pointer and geometry state
belong to the button's leaf view.

The floating tray presents a Regular glass status capsule and a separate native
glass Review button. Count and byte updates have no rolling numbers or emphasis
spring. The overlay still owns the tray's arrival. Actionable notices use a
borderless child action within one glass surface.

Reduce Motion removes the shared cards' hover translation, grouped disclosure
interpolation, animated setup indicator width and custom press scale. It keeps
stationary feedback. Cards and disabled result regions share refresh appearance
without sharing interaction policy. Existing refresh timings are retained for
this foundation pass; shortening visual recovery is a later measured change.

## Footprint inspection, 4 October 2026

The Apps inspector's footprint is now a set of equal groups, App, Settings,
Data, Background, Rebuilds and Other, each showing its count of locations,
with one group open at a time and its locations listed below. It replaces a
coloured size bar over one long list: the bar read as a chart of what removal
frees, and the evidence for an item sat far from its group's name. Equal
widths make no claim about proportion. The total and its location count stay
above the groups, and incomplete scanning and unreadable entries are stated
beside them rather than folded into a group.

Several ownership records for one path are one location, so a path is never
counted twice and a Shared record is kept even when stronger evidence names
the same place. A location whose observations disagree on size, or whose
size was not fully measured, shows its size as unknown rather than the larger
or smaller figure. Groups are worked out once per inspection, not while the
pane redraws.

Each location has an explicit Details control listing every record that
names it, strongest first, with a note when another app claims it or part of
it could not be read, and a Show in Finder link. That evidence used to be
hover help only. The hover-only Reveal button was removed from the row so the
name has room; Reveal remains in Details, the context menu and double-click.

Two classification faults surfaced while checking WhatsApp. A folder named
for an identifier ending in `.app`, such as `Containers/io.getpurge.app`, was
grouped as the app itself; only a bundle outside the Library is now. And the
Application Scripts folders sandboxed apps get were grouped as Other; they,
and Autosave Information, are Data, and `~/.config` is Settings.

Choosing a group replaces the list below at once, and only the selected
button's indicator moves. The planned 220 ms reveal was built and dropped
after watching it: the list drew the outgoing and incoming groups on top of
each other, and then, with a fade alone, scrolled the incoming rows up under
the group buttons for a moment before settling. A location's Details still
opens with a short spring, and Reduce Motion reduces it. The inspector
remembers which group was open, so checking Data for one app opens Data for
the next app that has any.

## Colour, 4 October 2026

Brim is dark only. The application's appearance is set to dark before any
window exists, so every window, sheet, menu and alert is dark whatever the
system setting; launching with a light-appearance override still drew dark.
The canvas is the system's own dark window background (#1E1E1E on macOS 27),
replacing Brim's own #0F0F11, which was darker than any app beside it. Cards
sit one step up at #2A2A2C, as grouped rows do in System Settings, with a
lighter variant for Increase Contrast.

Accent, selection and every progress or proportion bar use the person's
system accent, so Brim's highlights match the rest of their Mac. Status uses
the Okabe and Ito colour-universal palette, republished by Wong in Nature
Methods (2011), because its hues stay distinct under the three common forms
of colour blindness and differ in lightness too: bluish green for done,
orange for needs a look, vermilion for stopped or permanent, sky blue for
information. Each was measured against the canvas and the cards: green was
lifted 6% to reach 4.5:1 as text on a card, and vermilion, at 3.7:1, marks
icons only, with the word beside it carrying the meaning. Monograms use
system colours kept clear of the status hues. The eight hand-picked pastels
are gone.

## Review to result, 4 October 2026

The review and the result use the inspector's groups in the inspector's
order. Each review group lists what moves, what the person may include and
what stays with its reason, so the separate "You can also include" and
"Needs you" lists are gone from the app review. Installer receipts form a
Records group, and bookkeeping steps such as the privacy reset never appear
as file rows. The result's By group section reports each group's outcome
in the same order: gone, still here, not checked, left unticked or kept,
each counted once.

A verified success settles its mark once in place over 240 ms, opacity only
under Reduce Motion. A success with locations that could not be read is not
treated as verified and keeps a static caution mark. Stopped and unchecked
removals say what happened and what to do next, and Review Again builds a new
plan from the disk with its own approval; ticks from the earlier attempt are
not carried over. Closing the panel after a removal refreshes Apps even when
the last thing on screen was a Review Again.

The Journal keeps each record's last Put Back outcome beside it: progress,
then "Put back" or "Could not put back" with the reason behind a button.
The banner that used to report a failure above the list is gone. The control
area has a reserved width so the time beside it never moves.

## Interaction timing, 4 October 2026

A page chosen with the pointer fades in 180 ms; one chosen from the keyboard
(sidebar arrows, Command-digits, Back and Forward from the menu) appears at
once, detected from the event that caused the change. The earlier 280 ms
blur, scale and drift is gone. Arrowing through a list selects without a
crossfade. Toasts arrive in 180 ms and the tray in 220 ms from 4 points
below, both leaving in 120 ms. Disclosures use the 220 ms evidence token and
change immediately under Reduce Motion. Loading placeholders appear only
after a 150 ms wait. Refreshed content recovers in 180 ms instead of 600.
Check Again's turn and Reveal's bounce stop under Reduce Motion. Closing the
command bar returns focus to the control that had it, when it is still in
the window.

## Character, drop and onboarding, 4 October 2026

Welcome shows the character beside its greeting and About is a small window
with it. In both it leans toward the pointer, at most 3 degrees and 2 points
within a region no larger than 160 points, with text and buttons outside the
transform, no idle motion, and no tracking under Reduce Motion or in an
inactive window. Onboarding steps replace each other with a 220 ms fade and
4 points of travel, immediately under Reduce Motion.

The Home drop well shows one response to a drag, a defined inset edge,
instead of a tint, glass and a bouncing symbol together. A drop that is not
an app is refused the native way and the well says why.

## Narrow windows and refresh, 4 October 2026

The window minimum is 900 points instead of 1100. Apps, Background and
Developer lay out a list and its pane side by side when there is room for
both (the list's 440 plus the pane); narrower than that, the list takes the
width and the pane floats over its trailing edge while it has something to
show, with Close and Escape. The list keeps its scroll position and
selection across the threshold; the pane is rebuilt when it moves. Home's
four summary cards wrap two by two below 680 points. The 720 point
checkpoint from the plan was not adopted as a minimum: at that width Home,
Space and Energy would need their own redesign.

Apps stays browsable while it refreshes: scrolling, searching, selecting and
inspecting continue over the previous list, lightly dimmed. This is limited
to Apps because no action there trusts the old rows; removal always plans
afresh with its own approval and inspections check that their answer still
belongs to the selection. Remnants and the other pages still lock while
scanning, because their actions act on listed paths.

## Updates and feedback, 4 October 2026

A failed update shows a Details button with the reason beside Retry; the
reason used to be hover help only. Opening Installer is shown as the next
step, not with the finished checkmark, and the row's control has a reserved
place so Update, progress, result and Retry never move the text beside them.
Feedback's Copy report keeps its width when it says Copied, and why Send is
unavailable is said under the buttons, not only in hover help.

## Verification

The package suite completed 484 XCTest cases with one existing skip and no
failures, plus 253 passing Swift Testing cases. Real
registration lifecycle experiments were excluded. Direct enumeration of the
real Trash was refused by macOS, so the post-suite Trash contents could not be
independently checked.

The signed Debug build compiled with strict concurrency and warnings as errors.
On the real machine, Home displayed the sidebar identity and inspection action;
the chooser opened, cancelled without an alert, and selected an installed app
into its Apps inspector. Developer selection changed the tray from one to two
items, opened Review without approval, retained selection on Close, and cleared
both items and the tray. No removal was approved during these checks.

The signed Release build also compiled with strict concurrency and warnings as
errors. Its chooser opened in Applications with an Inspect action and returned
to Home cleanly on cancellation. The changed-file lint check added no
violations against the implementation baseline, `3fbc2f3f`.

A 15-second Time Profiler capture contained 15 running samples, five on the
main thread, without a continuous rendering loop in that capture. Process CPU
snapshots varied from 0% to 52.5%, and the process ended before a follow-up
sample could be collected. Frontmost state could not be held consistently
across the automation tools. These observations are inconclusive and do not
qualify the active-window idle budget or establish a performance improvement.
Pointer tracking and scrolling still need a controlled frame-time comparison.

System accessibility preferences were not changed for this verification. Their
new branches have been inspected in source; reduced-motion animation, VoiceOver
and contrast behavior still need a dedicated real-device walkthrough. A short
idle trace is not a launch benchmark or proof of frame-rate performance.

Footprint inspection was checked on the real Mac with WhatsApp, from Home's
Recently installed into Apps: App, Data and Rebuilds groups with 1, 18 and 3
locations; Data at 1.19 GB, largest first; the first location's Details
showing "Direct" with its entitlement sentence and Show in Finder; nothing
in Other after the classification fixes. Nothing was removed. Keyboard
selection of a group, a Shared location and VoiceOver reading of the groups
were not checked on the real Mac; the Shared and partial cases are covered by
unit tests only.

The second slice was built with the screen locked for most of the session,
then checked on the real Mac once it was unlocked. Seen working: the About
window and its close; Journal row alignment; the WhatsApp review grouped as
System records, App, Data (18) and Rebuilds (2), with an unticked crash
report marked as a name match, closed without removing anything; Home's
cards wrapping two by two at 900 points; and Remnants at 900 points.

The look found two faults that tests had passed. At 900 points the Apps
list stayed beside its pane, squeezed the sidebar and clipped the pane off
the window, because the list's own minimum width was what the adaptive
container measured. With that minimum removed the list takes the full width
and the pane floats with Close, which clears the selection. Page and pane
changes also drew both pages for a moment while one faded out and the other
in; the outgoing view now leaves at once, and a capture straight after a
sidebar click showed only the new page.

Not looked at on screen: toast and tray timing, the Welcome artwork (setup
was already complete), the drop well refusal, the update Details popover,
Apps browsing during Check Again, and Select mode in the narrow layout.
The full package suite passed (486 XCTest cases, one existing skip, and
the Swift Testing runs) and the changed-file lint added no violations.
Launch measurements are in `docs/performance.md`.

## Removal result

After eqMac was removed on the real Mac, its audio device left the Sound
menu at once, yet the result read as a partial removal. It showed a
caution mark, counts of places and kinds of registration checked, and
"cannot be checked" rows for VPN settings, privacy grants, cloud files and
configuration profiles. The last of those can never be fully read on this
Mac, so every removal had been marked incomplete.

A check that could not be answered now counts only for a kind of
registration the review had reason to expect. The result is built from
`RemovalSummary`:

- the app is gone, and how much is in the Trash or set aside;
- the groups that went, each with a check;
- only what actually stayed, quietly: unticked, kept on purpose, could not
  be moved, still listed by macOS, or a check that could not be answered
  for a kind the app declares.

Coverage counts and out of scope kinds are not shown. The batch panel
reads the same summary.

Checking the disk after eqMac found no driver, helper, receipt, login
record, preferences or privacy grant left. It did find:

- **Codex's Sparkle cache.** It had been moved to the Trash with eqMac, a
  misattribution through Sparkle.framework's shared identifier.
- **A stale Launch Services record** for eqMac's nested login helper.
- **Empty WebKit folders** in the per-user temporary folder.
- **An empty `Caches/SentryCrash/eqMac` folder.**

All four are fixed for later removals and covered by tests. The items
already on this Mac were left as they are. The new result was verified by
unit tests and a build only: the running copy was the person's own and was
not relaunched to look at it.

### Second eqMac removal

eqMac was reinstalled from its disk image and removed again with the new
build. The app, its audio driver, caches, settings, both Sentry report
folders (`SentryCrash/eqMac` and `io.sentry/<hash>`, the second found by
hashing the reporting address in its executable) and the nested helper's
Launch Services record all went; Codex's Sparkle cache was untouched.
WebKit's three folders in the per-user temporary folder were planned and
refused: macOS creates them with `SF_NOUNLINK`, so nobody can remove them.
Anything carrying a system protection flag is now left out of footprints
entirely. Core Audio kept the old driver loaded in memory throughout,
which is what the conditional restart note is for.

The same pass found two Journal and Apps faults. The Journal read installs
from the apps on the disk now, so a removed app lost every install and
Figma and eqMac showed two removals in a row; installs now come from the
snapshots and stay. And a removed app could stay selected in the Apps
inspector with its old footprint; a fresh list now clears it. Both are
covered by tests; neither has been looked at on screen yet.

### Put Back, the Journal and what removals missed

Recordly's Put Back restored every file and still read "Could not put
back". Its identifier ends in `.app`, so cache folders named for it were
planned as application bundles; re-registering one failed. A path that
exists is now an application only with a `Contents/Info.plist`, and Put
Back skips re-registering anything else.

The Journal can now be cleared (removals that can still be put back stay
listed) and can delete one removal's items, or all of them, from the
Trash after asking. Only the exact items those removals recorded are
deleted, and only while they are still in a Trash folder.

SystemEQ for Mac (`com.denzam.SystemEQ`) left `Application
Support/SystemEQ`, which no displayed name reaches; the identifier's last
label is now searched as a name. `Application Support/Microsoft` was
judged whole because Visual Studio Code's name does not begin with
Microsoft; a developer's folder is now opened in the person's Library as
in `/Library`. SystemEQ's install and Gatekeeper removal never appeared
because they happened between two of Brim's looks, which is by design.

### Why folders were missed, 5 October 2026

The label fix above was a patch for one app. Measured instead: Brim's
footprint for every installed app against a looser search of the data
folders (any name containing a distinctive part of the app's names or
identifier, any case), and the same for the fourteen apps history shows as
removed.

Where Brim looked was fine. Name matching failed three ways:

- **Comparison.** A folder counted only when its name equalled one of the
  app's names exactly. `Caches/Codex` was found for ChatGPT only because the
  volume ignores case, and the row carried the wrong spelling.
- **Names.** History kept one name per app, so after removal the sweep
  knew SystemEQ only as "SystemEQ for Mac". Worse, the developer folder
  rule from the previous batch treated `SystemEQ` as a developer's folder,
  because a recorded app name began with it, and judged `presets` inside it
  on its own. That was this session's regression.
- **Decision.** A name match was never ticked, and provenance, the only
  thing that could promote one, is absent on SystemEQ's folder and on the
  Visual Studio Code, WhatsApp and boringNotch bundles, and ChatGPT.app
  carries Claude's value. So `SystemEQ for Mac` was found and stayed.

The verification after the removal shared the removal's names, which is
why the miss was invisible, including to the check made in this session.

Changed: names are compared through `NameKey` (case, spaces and
punctuation ignored) everywhere, rows carry the on-disk spelling, names
gain the form without a platform word ("SystemEQ for Mac" gives
"SystemEQ"), history keeps every name, the sweep uses the full identity
in Brim's own uninstall plans, a folder that is itself an app's name is
never taken for a developer's, and `Caches/CloudKit/<identifier>` is a
location. A folder in an app's own data folders (Application Support,
Caches, Logs, HTTPStorages, WebKit, Saved Application State) named for it
is now ticked when the name is one it declares, or a derived name that is
not a dictionary word, and no other installed app answers to it. Anywhere
else a name match stays a suggestion.

Verified: both real machine audits (`FootprintAuditTests`,
`LeftoversAuditTests`, `BRIM_REAL_ENV=1`) pass on this Mac; Remnants on
the new build lists `Application Support/SystemEQ` (116.7 MB) under
SystemEQ for Mac and the WWDC app's CloudKit cache; Visual Studio Code's
review shows `Application Support/Code` ticked and the shared
`UBF8T346G9.ms` unticked. Nothing was removed.

Remaining: Microsoft AutoUpdate's `com.microsoft.autoupdate.fba` caches
are a helper identifier nothing recorded, so they appear only as unclaimed
once a week has passed since they were written. Snapshots record names but
not helper identifiers, which would need each bundle's parts read at every
look.

### Settings, feedback, sidebar and removing Brim, 5 October 2026

Settings is two tabs, General (Dock, Access, Privacy, Remove Brim as
sections) and Feedback, and opens on the tab used last. Feedback dropped
the recent reports list and the drafts note; Browse reports on GitHub
takes that card. Title (100) and description (5,000) are held to limits as
typed, with counts; the title prompt depends on the kind of report; the
description has a Dictation button using macOS Dictation, and its prompt
clears while the field is focused because dictated text is provisional
until committed. The steps disclosure opens from its title. Home is named
Brim with Brim's icon at 22 pt, and each sidebar symbol has its own
selection effect. Seen on screen: Settings, the composer, the counts,
Dictation starting from the button, the disclosure, the sidebar.

Remove Brim replaces Uninstall Brim, which trashed Brim's files and wrote
a journal into the folder it removed. Root's part (the `/Library` folder,
the system privacy grants) goes through the temporary administrator
process before quitting; a script waiting on a pipe Brim holds then clears
the preference domains and deletes the app and every path named for
Brim's identifiers, retracts Launch Services and deletes itself. Tested on
a fixture tree only. It has not been run on this Mac, because running it
deletes Brim and its history; the Settings section was not seen because
the screen locked.

Hover: nothing was removed by accident. The pointer light lived only in
the Inspect an app card, removed on request with that card; the card
lifts, row hovers and feedback cards remain. System buttons never had a
custom hover.

### Pointer light and capsule hover, 5 October 2026

The pointer light is one modifier (`PointerLight.swift`) on Home's cards
and the feedback cards. Capsule actions used `CapsuleActionStyle` for a
day (replaced the same day by native glass, below): bordered
system buttons have no hover state, and SwiftUI draws them as AppKit
controls above anything layered on them, so an overlay highlight was
invisible. Cards track the pointer with an AppKit tracking area, because
nested SwiftUI hover regions gave the pointer to the card and never to a
button on it (traced with a temporary log). Approval buttons stay native.
Seen on screen: the card light following the pointer. Not confirmed: the
capsule hover, since the automation pointer reaches tracking areas but no
button hover, native glass buttons included.

### Page titles, search and glass buttons, 5 October 2026

Every page drew its own title row under an empty toolbar. The first fix
used the system's toolbar title with the page's facts as a subtitle, and
two lines squeezed into the toolbar row made the name small and the row
crowded. Now `pageTitle(_:)` (`PageChrome.swift`) draws the page's name
alone in the toolbar row at 20 point semibold (`brimToolbarTitle`), with
no subtitle; the window keeps the name as its title. The page draws it
itself, so it starts exactly where the page's content starts: the page
padding on list pages, the centred column's edge on card pages. Lists add
8 points of their own, so Remnants and the Journal inset their rows by 16
to land on the same 24. The facts stay with
the lists that already show them in their section headers. Home's title
is the Mac's name. The same rule now holds for the review panels: the
Review, app removal and batch removal headers show the title alone, and
their counts and sizes moved beside the Remove button.

Page actions moved into the toolbar beside the refresh button: Update All,
the Journal's More menu. The refresh button is now the page's own: Take a
Reading on Energy (its separate button did the same thing), Scan Again on
Developer, Check Again elsewhere. While a page works it turns into a
spinner, which replaced a spinner beside each title, and a Developer scan
can be stopped from it.

Search is `BrimSearchField`: a glass capsule with the magnifying glass, a
clear button, Escape to clear and Command-F to focus. On Apps it shares one
row with Group By, Select and the view switch. Apps and Updates are
`LensSwitch`, a capsule whose lit half slides between the two, with the
update count as an accent badge; VoiceOver gets a segmented picker.

Buttons are glass: `capsuleAction()` is `.glass` or `.glassProminent`,
every window defaults unstyled buttons to `.glass`, and the approval
buttons are `.glassProminent`. Rows, links and icon buttons keep their
own styles. Button labels are title case throughout. Card pages (Home,
Space, Energy) share `Metrics.cardSpacing` and `Metrics.cardPageWidth`,
and every card on them lifts with the pointer light as Home's do; the
volume card, dense with figures, lifts 1 point under half the light.

Verified: the build, the full suite, lint, and the layout of every page
from Brim's own window drawn to a file. That drawing does not render
glass, so the glass buttons, the search capsule and the lens switch's light
have not been seen as glass, and their hover needs a real mouse.

### Cards letting go of the pointer, 5 October 2026

Cards stayed lit and raised after the pointer left, on every page with
the light. A card's lift and scrolling rebuild its tracking area with the
pointer inside, and AppKit reports leaving only an area it saw entered. A
first fix that re-checked the pointer on each rebuild lit the card with no
exit to follow and made it worse. `PointerTracking` now rebuilds with
`assumeInside` when the pointer is in the area, and `PointerWatch` (one
local and one global monitor) re-checks every view that thinks it holds
the pointer on every move. Every card answers through `hoverLift()` at one
strength: a third of the light, a 1 point rise, a faint shadow; the
Settings feedback cards lost their own light and background change. The
sidebar reads Home again, Home's title is Home, and every sidebar icon
answers a click with the short press Apps has.

Verified: build and lint. Not verified: the pointer letting go, because
the synthetic pointer did not light a card even while over it, so those
captures proved nothing. It needs a real mouse.

### Audit fixes and monochrome, 5 October 2026

An audit against Apple's guidelines (toolbars, materials, buttons, writing,
motion, colour, accessibility) and published lists of generated-UI and
generated-writing tells found glass in the content layer, the system accent
carrying data, 2.3:1 text, five VoiceOver failures, contradictory status
and a recognisable machine cadence in the copy. Changed:

- Monochrome. Measures, selection, links, tiles and control tint are
  whites and greys (`Palette.snow`, `frost`, `mist`, `tint`, `selected`);
  only status keeps the Okabe–Ito colours.
- Glass only where it floats. Action buttons are `ActionStyle` (a snow
  capsule for the main action, a faint one otherwise), the search field is
  flat, and unstyled buttons are the system's push buttons again.
- `Palette.inkTertiary` raised from 2.3:1 to about 4.6:1.
- VoiceOver: the Settings Dock switch is named, the Energy cards and the
  Space meter have a role, Home's arrow is hidden, "1 locations" fixed, the
  Remnants section header is one heading.
- Status: Home and Space share one rule for the Remnants dot, zero bytes is
  "0 KB" rather than "Empty", Brim's recovery copies have their own heading
  instead of sitting under Unknown, unknown rows show the real folder name,
  a lone extension names itself, project caches show their folder, and old
  Journal rows named Leftovers read Remnants.
- Wording: Review All and Review Selected instead of Delete, Show in Finder
  everywhere, Try Again, no "we", and the sentences built on ", so" or "not
  X" rewritten plainly.
- Motion: sidebar icons no longer animate; cards keep only the faint light.
- Titles: Apps and Updates draw no title beside their switch, and drawn
  titles dim in an inactive window.
- Menus: Update All, Empty Removed Items from Trash, Clear Journal and
  Updates are in the menu bar.

Verified: build, the full suite (pinned copy updated in five tests) and
lint. Not seen on screen: the screen was locked when the captures ran, and
glass never renders in them. The Home grid that repeats the sidebar, the
empty right-hand pane at rest, and the ✕ badge on Journal install rows are
not changed.

### Update checks seeing new releases, 5 October 2026

ChatGPT offered an update while Brim reported no updates. The installed
version was 26.930.41038; the cached Homebrew catalogue, written the previous
evening, still named that version. The [publisher's current entry](https://formulae.brew.sh/api/cask/chatgpt.json)
named 26.930.51102. ChatGPT.app identifies as `com.openai.codex` and has
no `SUFeedURL`, so this check uses the public catalogue. There was no
bundle-specific matching defect.

Check Again skipped contacting the catalogue publisher until the cache
was 24 hours old. Opening Updates separately reused its last result for
six hours. A failed download could also reuse the old catalogue and call
an app current without fresh evidence. Each requested check now creates
one shared catalogue request, bypasses Foundation's local response cache,
and sends the saved ETag only with a valid saved catalogue. A conditional
304 confirms that data; a valid 200 replaces it. Failed or malformed
responses leave affected apps unchecked. The Updates page checks on entry;
Home keeps its six-hour summary reuse. No timer or resident worker was added.
The page's zero-update message now distinguishes checked apps from a check
that could not reach any source.

Verification: the first five regression tests failed against the old code
with 13 failed assertions. Seven final tests cover a new release inside
the old cache window, 304 validation, repeated use of a finder, missing
ETags, invalid caches, failed responses and one request shared by concurrent
callers. The full strict package suite passes: 920 XCTest cases, 41 existing
skips, plus 256 Swift Testing tests. The signed Debug app builds with strict
concurrency and warnings as errors; lint adds no findings. That build also
caught an unused result in the window's drop handler, whose closure now
explicitly returns Bool. Its drag interaction was not exercised here.

On this Mac, the old app's Check Again began showing ChatGPT once the
24-hour cache cutoff passed, before the fix was built. The fresh-cache miss
is reproduced by the regression fixture. The rebuilt app shows one
available ChatGPT update on entering Updates, checking again, and returning
from Home, whose summary also shows one available. No app update or removal
was performed. The test Trash and catalogue fixture folders were cleaned
by their harnesses; this session could not read the real Trash because
macOS refused access.

## No background registration (6 October)

System Settings listed Brim under Background App Activity, switched on and
"last ran in background 3 days ago", although protected work had moved to
the temporary administrator process on 3 October. The bundle still carried
the old daemon's launchd plist, and every launch called
`SMAppService.unregister` to retire it; each Service Management call makes
macOS evaluate that plist again, so the record followed every new build.
The plist is no longer embedded, Brim makes no Service Management call, and
`HelperLifecycleTests` fails if either returns. A clean build has no
`Contents/Library`. The record macOS already held stayed after every Brim
build, test leftover and data folder was removed from this Mac; it can only
be switched off in Settings, since erasing it would need a global reset.

## Energy and Space, first phase (6 October)

Plan in `plans/008-energy-and-space.md`. Energy's two condition cards are
one status card: charge with a meter, the whole Mac's draw from the battery
controller's telemetry, the adapter's rating, and the temperature, with a
line of battery health read from `system_profiler` so it matches Settings
(the registry's own capacities give 98.5% where Settings shows 100%). The
power list measures each app against the total rather than the busiest,
folds everything past six rows into one, and offers Quit on hover, in the
context menu and as an accessibility action; it is a polite quit and never
Brim itself. Space's Remnants and Developer cards became one card of bars
on the used space: apps, developer caches, Brim's removals still in the
Trash, and remnants, with the rest stated as a subtraction.

Verified: the readings against this MacBook Air (80%, 35 W adapter, 17 W
draw, Good, 100%, 55 cycles) in `BatteryReportTests`; the full package
suite (518 XCTest cases, 1 skipped, plus the Swift Testing suites); the app
build; no added lint. Not verified: the pages on screen, the draw figure on
battery power, Quit with a real pointer, and a Mac without a battery.

## Energy, second phase: the last few days (6 October)

Energy now reads `pmset -g log`, power management's own record, when a
reading is taken: about a week of sleeps and wakes with the charge at each,
and every request to keep the Mac awake with how long it was held. Nothing
watches; macOS wrote the record whether Brim ran or not. "Last 24 hours" is
the charge on a fixed 0 to 100% scale with the time asleep shaded behind it
(Swift Charts, a line and rectangles) and one line naming the last sleep of
half an hour or more and what it used, or that it was on the adapter.
"Asked the Mac to stay awake" replaces the card that listed only what held
the Mac at the moment of the reading: requests are added up per app over
the days the log covers, overlaps counted once, and an app holding one now
is marked Now. "Asked" is deliberate; a request only stops sleep while the
Mac is idle.

Attribution is by record. A process is named only when exactly one
installed bundle has that executable; `runningboardd`'s requests count only
when they name the application they were made for. Safari is reached
through /Applications and through the system Cryptex, which made its
executable look ambiguous until copies with one identifier became one app.

Measured on this Mac: the log covers 29 September to now, 497 charge
points, 27 sleeps; ChatGPT asked for 30.6 h, Claude 28.4 h, Safari 21.6 h,
Music 6.4 h. Reading and parsing took 4.4 s, 2.5 s of it `pmset` itself;
filtering lines before parsing dates took the parse from about four seconds
to under two. It runs beside the reading, behind a placeholder. Not
verified: the two cards on screen, and a desktop Mac.

## Space, third phase, and stale privacy grants (6 October)

Space inspects every installed app with the Apps inspector's footprint,
three at a time (nineteen apps, about thirteen seconds here), and shows
their data outside the bundle as its own row and as the second tone in
Largest apps. Claude's bundle is 0.9 GB and its data 13 GB. Shared folders
are counted once, for the claimant with the larger bundle (the Claude Code
URL Handler app claims the same 13 GB), nested folders once, and whatever
the Developer caches row counts is taken out. Each finished visit records
its figures in Brim's preferences; "Since you last looked" subtracts the
previous visit, visits within an hour being one look. Seen on screen:
App data 22.18 GB, everything else 88.26 GB, free space 858 MB less than
the morning's visit, Largest apps led by Claude at 14.19 GB.

Full Disk Access still listed Microsoft AutoUpdate's removed helper.
`PrivacyGrantSurface` reads both privacy databases read only and reports
grants to program paths no longer on disk, report only, routed to Privacy &
Security. Background had filtered out everything not tied to an installed
app, which hid it; it now shows under Still listed. Seen on screen. Not
verified: removing it through Settings and the row clearing on refresh.

The day chart breaks at restarts and dashes time on the adapter; the
sleep sentence names its times. Brim keeps the system accent out entirely
(Graphite in its own preferences, off-white icons, off-white selections
with #1E1E1E text, Settings tabs by colour alone). Full Disk Access
requests are remembered so a relaunch returns to the same page.

## Before and after an install (6 October, plan 009)

Three features carry Brim's evidence to the moments it did not cover.
Looking inside an installer reads a package's own file list (`pkgutil
--expand`, `lsbom`), scripts and declared bundles, a disk image mounted
read-only and hidden, or an app's bundle, and installs nothing. Recording an
install takes two snapshots of every place software hides, 0.09 s each, and
attributes what is new by name, developer or registration; what only
appeared during the recording is shown unticked. A kept recording becomes
Tier B evidence for the removal and is offered in Remnants once the app has
gone. Rechecks look again, by path, at every confirmed removal when the
Journal or Home opens.

Found by looking: the snapshot missed new apps because the Applications
folders are not in the location table; a new developer folder
(`Application Support/VendorCo`) was not linked to `com.vendorco.demo`; Brim's
own root-owned folder was reported as unreadable and its own folders would
have appeared as noise. All fixed, and Brim's names are read from its bundle,
not listed. Package sizes under a megabyte said nothing beside a launch job
and are hidden.

Home is now four equal columns with level rows: Space (with the largest app
and the change between Space's last two looks), Energy (charge, charging,
health, cycles, the last long sleep named by its day), the four counts,
Installing, and the Journal (removals, and whether they are still gone). A
`Grid` divided its columns by what each card asked for and broke "Updates"
across two lines; rows are equal-width stacks measured at their tallest.

Seen on screen through a temporary capture hook, since removed: both
previews, the recording card before and after a relaunch, an empty and a
real result, and Home. Not seen: a Journal row that came back (no removals
existed and the screen was locked), and Home's two-column layout.

Later the same day the preview gained Install, so a recording no longer
needs the person to start and stop it. Brim copies an app into Applications
itself after checking it again, or opens a package in Apple's Installer,
records around either, and finishes when the app first quits or Installer
does, keeping what is linked without asking. Update downloads now show
their sizes: ChatGPT's whole app is a 1.3 GB archive and its row sat on one
percentage long enough to look stuck. The Apps switch has room inside it.
Not seen on screen: the Install flow and the padded switch.

## Remaining design work

Needs a person or hardware this session did not have: the real-device
walkthroughs with Reduce Motion, Reduce Transparency, Increase Contrast and
VoiceOver (macOS offers no per-app override, and system settings were not
changed); 120 Hz frame captures of pointer tracking and scrolling; frontmost
idle CPU with the screen unlocked; the formative usability study; and
Developer ID notarisation, which needs the paid programme and is not
planned: Brim ships as an open source DMG signed with the free certificate.

Deferred deliberately: a toolbar search field (the existing field is
already visible and keyboard reachable, and no improvement was shown); a
native inspector container (the adaptive panes cover narrow windows without
changing the evidence pane); showing the Apps list before sizes arrive,
which would make every size optional and touch sorting and grouping.
