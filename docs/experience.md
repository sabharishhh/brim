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

## Remaining design work

The footprint presentation, review-to-result continuity, adaptive inspector,
read-only browsing during refresh, artwork depth, and the broader interaction
matrix remain planned. This first slice establishes the shared controls and
motion behavior before that work changes more screens.
