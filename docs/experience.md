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
opens with a short spring, and Reduce Motion reduces it. A narrow-window inspection sheet was not added: at the 1100 pt minimum
window the list and inspector both fit, so it could not be reached. It
belongs with the adaptive layout work, before the minimum is lowered.

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

## Remaining design work

Review-to-result continuity, the adaptive inspector, read-only browsing
during refresh, artwork depth, and the broader interaction matrix remain
planned. The footprint groups are not yet carried into the review and the
result, which is the next step of the footprint-to-result direction.
