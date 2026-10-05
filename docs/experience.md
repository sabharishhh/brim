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
and the feedback cards. Capsule actions use `CapsuleActionStyle`: bordered
system buttons have no hover state, and SwiftUI draws them as AppKit
controls above anything layered on them, so an overlay highlight was
invisible. Cards track the pointer with an AppKit tracking area, because
nested SwiftUI hover regions gave the pointer to the card and never to a
button on it (traced with a temporary log). Approval buttons stay native.
Seen on screen: the card light following the pointer. Not confirmed: the
capsule hover, since the automation pointer reaches tracking areas but no
button hover, native glass buttons included.

## Remaining design work

Needs a person or hardware this session did not have: the real-device
walkthroughs with Reduce Motion, Reduce Transparency, Increase Contrast and
VoiceOver (macOS offers no per-app override, and system settings were not
changed); 120 Hz frame captures of pointer tracking and scrolling; frontmost
idle CPU with the screen unlocked; the formative usability study; and
Developer ID notarisation, which needs the paid programme.

Deferred deliberately: a toolbar search field (the existing field is
already visible and keyboard reachable, and no improvement was shown); a
native inspector container (the adaptive panes cover narrow windows without
changing the evidence pane); showing the Apps list before sizes arrive,
which would make every size optional and touch sorting and grouping.
