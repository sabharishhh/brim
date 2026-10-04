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

The separate Home follow-up implements recent installs and reinstalls, restore
counts after Trash is emptied, and Remnants measurement and wording. Home no
longer displays Changes or requests its history during an app refresh. These fixes are separate from the performance change.

## Combined performance and Home audit, 4 October 2026

The audit traced shared inventory reads, ownership reuse, bounded measurements,
selection cancellation, planner containment, recent installation history and
recovery summaries. No further defect was found in the performance algorithms.
The existing component timings remain the evidence for their speed improvement.

Three defects were corrected. Registration maintenance returned a different
value type from its protocol requirement, so Home invoked the default no-op.
It now satisfies the protocol, and the existing lifecycle test calls through
that interface. Undo now checks the stopped job declaration's recorded file
identity and modification time before offering or executing its restore route.
A replacement at the same path cannot be started by that earlier removal.
Space now carries incomplete remnants measurements into its figure, showing
a lower bound or Size unavailable instead of an exact size or Empty.

Regression fixtures cover the protocol signature, same-date replacement,
in-place declaration edits and unreadable remnants with zero or partial bytes.
The full package suite passed: 484 XCTest cases with one existing skip and
253 Swift Testing cases. After extracting the launch-job recovery check into
a small function, its eight focused regressions passed again. The final
Release build, strict signature check and lint comparison passed with no new
violations. The installed build loaded Home and Space, completed small and
large inspectors, retained the latest rapid selection and prepared a removal
review. The review was closed without approval. Real registration lifecycle
experiments were excluded; the protocol regression does not establish live
record erasure.

## Lint and CI cleanup, 4 October 2026

The merged work added 560 formatting and lint findings compared with the
previous main branch. These blocked CI even though builds and tests passed.
Formatting, clearer local names and small extractions remove those additions
without changing the rules or replacing the baseline. New companion files
must pass both tools without an allowance. Older unrelated lint debt remains.

The update downloader, replacement and verification routines, helper receipt
and quarantine routines, bundle metadata reader and index writes now live in
smaller files. Removal checks, command order, cancellation, update decoding and
recovery boundaries retain their existing behavior. Independent reviews found
no behavioral regression. Test fixtures were split without dropping cases.

The full strict Swift suite passed with 484 XCTest cases (one existing skip)
and 253 Swift Testing cases. The 12 script tests passed. The signed Release
build and strict signature
verification passed. The built app loaded Home, the application list, an
associated-file inspector and a removal review. The review was closed without
approval. No real removal or registration lifecycle experiment was performed.
Hosted CI results are recorded in the pull request.
