# Loading and review performance

## Implemented, 4 October 2026

Review planning checks each path's ancestors against a set of selected roots.
It no longer compares every item with every selected path. Nested removals,
path boundaries, exclusions, fingerprints and privileged scope keep their
existing rules. The preliminary registration plan and final plan remain
separate, preserving registration binding.

The shared-item veto reads installed bundles and raw protection claims once
per evaluation, using that result for both component and group ownership.
Registered copies outside normal application folders and groups from bundles
without a host identifier remain protected. Incomplete or cancelled reads
still remove automatic selections. Nothing is cached between reviews.

Apps and Updates share an enumeration only while it is running. Update recovery
finishes before that read. Interrupted-update reasons remain available until
Updates consumes them, and only Apps writes an inventory snapshot. Cancelling
one waiter does not cancel another page's shared read. A later refresh reads
again.

Independent footprint measurements use the existing four-worker task helper.
Results retain evidence order, broken links and partial-read reporting.
Aggregate accounting remains separate to avoid counting overlapping roots or
hard links twice. Selection-owned bundle and identity reads retain cancellation;
cancelled inspection and planning stop before returning or storing a result.
Blocking native calls can finish before they observe cancellation.

Volumes publish when their request completes, while the leftovers estimate
continues. Space displays Checking for an estimate that has not arrived and
retains the previous estimate during refresh.

## Evidence and limits

Before implementation, native stack samples captured the repeated protection
reads and the planner's selected-path comparison loop. They did not establish
a reliable whole-app baseline.

The component comparison compiled the original planner and projector from
`a112846b` with optimization and compared them with the Release build. Identical
fixture inputs produced identical steps, exclusions, items and completeness.
Medians across three runs on this Mac were:

| Component | Original | Updated | Fixture |
| --- | ---: | ---: | --- |
| Complete planner call | 360 ms | 25 ms | 2,803 independent selected locations |
| Footprint projection | 55 ms | 20 ms | 32 directories containing 8,192 files |

A separate sizing probe compared one, two and four workers, rotating their
order. Medians were 53 ms, 33 ms and 19 ms respectively. Its peak resident memory
was 22 MB; the combined planner/projector comparison peaked at 35 MB. These
local fixture timings are not a whole-app speed multiplier or a cold-disk
benchmark. The temporary probe sources and fixtures are not shipped.

The signed Release app was opened on the real machine. It listed 88 apps,
loaded small and large inspectors, rejected obsolete rapid-selection results,
and prepared the large review from a footprint containing 2,804 locations.
No removal was approved. A native sample recorded 130 MB physical footprint
and a 196 MB peak. UI observation overhead and cached accessibility diffs mean
these observations are not precise launch or review timings.

The final full Swift package suite passed. Regression coverage checks nested
planning, privileged parents, ordered measurements, raw group claims, unknown
host identifiers, cancellation, inventory sharing and freshness, update recovery,
snapshot ownership and early volume publication. The Release build and strict
signature verification passed. Real registration lifecycle experiments were
not run for this performance change.

## Deferred

The application list still waits for bundle sizes, and the inspector still
waits for complete discovery and aggregate accounting. Broader consolidation
across evidence sources, progressive inspector output, developer discovery
remain outside this performance pass. The separate Home follow-up reuses the
existing bounded size reader for leftovers. No language migration,
persistent index or background service was introduced.

The separate Home follow-up implements recent installs and reinstalls, weekly
Changes history, restore counts after Trash is emptied, and Remnants measurement
and wording. These fixes are separate from the performance change.
