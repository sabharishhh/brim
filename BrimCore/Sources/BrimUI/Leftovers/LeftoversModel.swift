import BrimCore
import BrimProtocol
import Combine
import Foundation
import os

/// Backs the Leftovers view.
///
/// The two categories are kept apart at every level (separate sections,
/// separate selection, separate totals) because they answer different
/// questions and carry different risk. **Orphaned** means a record named an
/// owner and that owner has gone, which is evidence, so these may be
/// pre-selected. **Unclaimed** means the search came back empty, which is
/// not evidence of anything, so these are shown and never pre-selected.
/// Collapsing them into one list would quietly pre-select the second kind.
@MainActor
public final class LeftoversModel: ObservableObject {
    @Published public private(set) var orphaned: [Leftover] = []
    @Published public private(set) var unclaimed: [Leftover] = []
    @Published public private(set) var isScanning = false
    /// When the last scan finished, for "Checked 2 hours ago". Nil until
    /// one has, which is "not checked", never "checked and empty".
    @Published public private(set) var checkedAt: Date?
    @Published public private(set) var errorMessage: String?

    /// Chosen for removal. Orphans start selected, unclaimed items never do.
    ///
    /// Written only through this model, so there is one place to work the
    /// derived answers out. Every mutation below ends in `settle()`, which
    /// is also why selecting every removed app's items costs one pass
    /// rather than one per item.
    @Published public private(set) var selection: Set<String> = []

    private var service: (any BrimServiceProtocol)?
    private var hasLoaded = false

    public init() {}

    public var all: [Leftover] {
        orphaned + unclaimed
    }

    /// Unknown items shown for review use the same rule on Home and Remnants.
    public var unclaimedGroupsForReview: [LeftoverGroup] {
        unclaimedGroups.filter { Self.isWorthReview($0) }
    }

    public var hasUnreadRecoveryCopies: Bool {
        unclaimed.contains { $0.url.path == RecoveryCopy.directory }
    }

    /// One entry per piece of software rather than one per path. The list
    /// was unreadable per-path: the same tool appeared several times with
    /// nothing connecting the rows.
    ///
    /// Published rather than computed. As computed properties these grouped
    /// two hundred and fifty items from scratch on every read, and they are
    /// read several times per body evaluation: by Home's card, by each
    /// section and by the command bar. Grouping is pure, so the
    /// answer only changes when the arrays do, which is where it is done now.
    @Published public private(set) var orphanedGroups: [LeftoverGroup] = []
    @Published public private(set) var unclaimedGroups: [LeftoverGroup] = []

    /// A group asked for from outside the page, by the command bar. Remnants
    /// opens its card and clears this.
    @Published public var requested: LeftoverGroup?

    /// Selection is per group: a user reasons about software, not paths.
    public func isSelected(_ group: LeftoverGroup) -> Bool {
        let removable = group.items.filter(\.canBeRemovedByBrim)
        return !removable.isEmpty && removable.allSatisfy { selection.contains($0.id) }
    }

    public func toggle(_ group: LeftoverGroup) {
        let ids = group.items.map(\.id)
        if isSelected(group) {
            selection.subtract(ids)
        } else {
            selection.formUnion(group.items.filter(\.canBeRemovedByBrim).map(\.id))
        }
        settle()
    }

    public func deselectAll(in items: [Leftover]) {
        selection.subtract(items.map(\.id))
        settle()
    }

    /// What is ticked. Worked out when the selection or the scan changes,
    /// which is the only time it can, rather than by filtering every
    /// leftover on the Mac each time the footer is drawn.
    @Published public private(set) var selectedItems: [Leftover] = []

    /// Nothing Brim cannot remove is ever ticked: a group's tick and Review
    /// All take only removable items, so a removal is never refused at the
    /// end for something that was offered at the start.
    public var canRemoveSelection: Bool {
        !selectedItems.isEmpty
    }

    /// Unknown owners require an explicit selection. Bulk removal includes
    /// only known remnants, including items covered by administrator cleanup.
    public var removableOrphans: [Leftover] {
        orphanedGroups.flatMap(\.items).filter(\.canBeRemovedByBrim)
    }

    public func selectAllRemovableOrphans() {
        selection = Set(removableOrphans.map(\.id))
        settle()
    }

    /// Rows Brim removed, kept so they can come back if the person does.
    ///
    /// Dropping a row is not the end of the story. Everything here went to
    /// the Trash, and the Trash is a place people take things out of again.
    /// Restoring one in Finder puts the file back exactly where it was, and
    /// a list that had already forgotten it would go on claiming it was
    /// gone until the next full scan.
    private var removedButRecoverable: [Leftover] = []

    /// Drops what a removal proved gone, right now.
    ///
    /// The scan is not re-run. `verify` re-observed every path with `lstat`
    /// and said which ones survived, so the list already has its answer and
    /// walking the whole Mac again to rediscover it is four hundred
    /// milliseconds of making somebody wait for news they have been given.
    /// Anything still on disk stays on screen, because it is still there.
    public func forget(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let going = all.filter { paths.contains($0.url.path) }
        guard !going.isEmpty else { return }

        removedButRecoverable.append(contentsOf: going)
        orphaned.removeAll { paths.contains($0.url.path) }
        unclaimed.removeAll { paths.contains($0.url.path) }
        selection.subtract(going.map(\.id))
        regroup()
    }

    /// Puts back anything that has reappeared on disk.
    ///
    /// Called when the Trash changes. Restoring from Finder writes the file
    /// back to the path it came from, so the question is simply whether it
    /// is there again, which is one `lstat` per row Brim removed and
    /// nothing at all once that list is empty.
    public func reconcileWithDisk() {
        guard !removedButRecoverable.isEmpty else { return }
        let back = removedButRecoverable.filter { PathExistence.exists(at: $0.url) }
        guard !back.isEmpty else { return }

        let returning = Set(back.map(\.id))
        removedButRecoverable.removeAll { returning.contains($0.id) }
        orphaned.append(contentsOf: back.filter { $0.category == .orphaned })
        unclaimed.append(contentsOf: back.filter { $0.category == .unclaimed })
        regroup()
    }

    /// The one place the two arrays become the two grouped lists.
    ///
    /// `load` used to do this inline, so anything else that changed the
    /// arrays had to remember to redo the grouping and the selection by
    /// hand. Removing a row is exactly that kind of change.
    private func regroup() {
        orphanedGroups = orphaned.groupedByOwner()
        unclaimedGroups = unclaimed.groupedByOwner()
        settle()
    }

    /// The one place the selection's consequences are worked out. Called
    /// after a batch of changes, never inside the loop making them.
    private func settle() {
        selectedItems = all.filter { selection.contains($0.id) }
    }

    /// Scans only if there is nothing to show. Returning to a section is a
    /// change of view, not a reason to walk the disk again; rescanning is
    /// what Check Again is for.
    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        // Coming back to the section is not a reason to walk the disk, but
        // it is a reason to catch up on anything restored from the Trash
        // while the person was elsewhere, which the view could not see
        // because it was not on screen to be told.
        reconcileWithDisk()
        guard !hasLoaded, !isScanning else { return }
        await load(service: service)
    }

    private var loadTask: Task<Void, Never>?

    /// The section owns its scan. Navigation can cancel a view's waiter without
    /// discarding the result or leaving a second view waiting on an empty model.
    public func load(service: any BrimServiceProtocol) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad(service: service) }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoad(service: any BrimServiceProtocol) async {
        guard !isScanning else { return }
        self.service = service
        isScanning = true
        let interval = BrimLog.signposter.beginInterval("Remnants scan")
        defer {
            isScanning = false
            BrimLog.signposter.endInterval("Remnants scan", interval)
        }

        do {
            let found = try await service.leftovers()
            try Task.checkCancellation()
            hasLoaded = true
            checkedAt = Date()
            orphaned = found.filter { $0.category == .orphaned }
            unclaimed = found.filter { $0.category == .unclaimed }
            // Only orphans are pre-selected, and only the ones Brim can
            // actually act on.
            selection = Set(orphaned.filter(\.canBeRemovedByBrim).map(\.id))
            // A fresh scan is the truth, so nothing is being held back for
            // a restore that the scan itself would have found.
            removedButRecoverable = []
            regroup()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            hasLoaded = false
            checkedAt = nil
            // A failed sweep must not leave the last run's rows on screen
            // looking like this one's answer.
            orphaned = []
            unclaimed = []
            selection = []
            removedButRecoverable = []
            regroup()
            errorMessage = error.localizedDescription
        }
    }

    /// The plan intent for one removed app's traces, named for the app so
    /// the review says whose they are.
    public func removalIntent(for group: LeftoverGroup, requesterIdentity: String) -> PlanIntent? {
        let targets = group.items.filter(\.canBeRemovedByBrim).map(\.url)
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: group.displayName),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }

    /// The plan intent for the current selection.
    ///
    /// Named targets, not an identity: these items have no owner by
    /// definition, so there is nothing to discover a footprint from. The
    /// planner treats an intent with explicit targets as tidying rather than
    /// uninstalling, which is exactly right: it must not clear privacy
    /// grants or retract registrations for an app that is already gone.
    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        guard !isScanning, canRemoveSelection else { return nil }
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Remnants"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }
}
