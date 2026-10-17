import BrimCore
import BrimProtocol
import Combine
import Foundation
import os

/// Backs Remnants. Orphaned and unclaimed items stay apart at every level:
/// orphaned means a record named an owner that has gone, which is evidence,
/// so they may be pre-selected; unclaimed means the search came back empty,
/// which is not evidence, so they are never pre-selected.
@MainActor
public final class LeftoversModel: ObservableObject {
    @Published public private(set) var orphaned: [Leftover] = []
    @Published public private(set) var unclaimed: [Leftover] = []
    @Published public private(set) var isScanning = false
    /// When the last scan finished. Nil until one has: "not checked", never
    /// "checked and empty".
    @Published public private(set) var checkedAt: Date?
    @Published public private(set) var errorMessage: String?

    /// Chosen for removal. Orphans start selected, unclaimed items never do.
    /// Written only through this model; every change ends in `settle()`.
    @Published public private(set) var selection: Set<String> = []

    /// The rows shown are the last launch's and this launch's scan has not
    /// finished. Shown, but none can be ticked or removed: a kept answer cannot
    /// support a claim about the disk now.
    @Published public private(set) var isProvisional = false

    private var service: (any BrimServiceProtocol)?
    private var hasLoaded = false
    private let cache: PageCache<[Leftover]>?

    public init(cache: PageCache<[Leftover]>? = nil) {
        self.cache = cache
        guard let kept = cache?.load() else { return }
        orphaned = kept.value.filter { $0.category == .orphaned }
        unclaimed = kept.value.filter { $0.category == .unclaimed }
        checkedAt = kept.savedAt
        isProvisional = true
        regroup()
    }

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

    /// One entry per piece of software rather than one per path. Published
    /// rather than computed, because several views read it each pass and it
    /// changes only when the arrays do.
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
        guard !isProvisional else { return }
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

    /// What is ticked, worked out when the selection or the scan changes.
    @Published public private(set) var selectedItems: [Leftover] = []

    /// Nothing Brim cannot remove is ever ticked, so a removal is never refused
    /// at the end for something offered at the start.
    public var canRemoveSelection: Bool {
        !selectedItems.isEmpty
    }

    /// Unknown owners require an explicit selection. Bulk removal includes
    /// only known remnants, including items covered by administrator cleanup.
    public var removableOrphans: [Leftover] {
        orphanedGroups.flatMap(\.items).filter(\.canBeRemovedByBrim)
    }

    public func selectAllRemovableOrphans() {
        guard !isProvisional else { return }
        selection = Set(removableOrphans.map(\.id))
        settle()
    }

    /// Rows Brim removed, kept in case the person puts them back from the Trash,
    /// which restores a file exactly where it was.
    private var removedButRecoverable: [Leftover] = []

    /// Drops what a removal proved gone, without rescanning: `verify` already
    /// re-observed every path. Anything still on disk stays on screen.
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

    /// Puts back anything that reappeared on disk. Called when the Trash
    /// changes: one `lstat` per row Brim removed.
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

    /// The one place the two arrays become the two grouped lists, so any change
    /// to the arrays regroups and resettles.
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

    /// Scans when there is nothing confirmed to show, or the result is stale.
    /// Returning to the section is not a reason to walk the disk.
    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        // But catch up on anything restored from the Trash meanwhile.
        reconcileWithDisk()
        guard !hasLoaded || isStale, !isScanning else { return }
        await load(service: service)
    }

    /// Something happened that can change what is left: an app arrived or went,
    /// or Brim was away long enough. The next look scans again.
    public func markStale() {
        needsScan = true
    }

    private var needsScan = false

    /// How long a result counts as current without anything saying it changed.
    /// Apps writing into Library do not count; they write all the time.
    public static let freshFor: TimeInterval = 3600

    public var isStale: Bool {
        needsScan || checkedAt.map { Date().timeIntervalSince($0) > Self.freshFor } ?? true
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
            // A rescan keeps the person's ticks; only something new is ticked as a
            // first scan would.
            let rescan = hasLoaded && !isProvisional
            let shownBefore = Set(all.map(\.id))
            let pickedBefore = selection
            needsScan = false
            hasLoaded = true
            isProvisional = false
            checkedAt = Date()
            cache?.save(found)
            orphaned = found.filter { $0.category == .orphaned }
            unclaimed = found.filter { $0.category == .unclaimed }
            // Only orphans are pre-selected, and only the ones Brim can
            // actually act on.
            let preselected = Set(orphaned.filter(\.canBeRemovedByBrim).map(\.id))
            selection = rescan
                ? pickedBefore.intersection(found.map(\.id)).union(preselected.subtracting(shownBefore))
                : preselected
            // A fresh scan would have found any restore, so nothing is held back.
            removedButRecoverable = []
            regroup()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            hasLoaded = false
            isProvisional = false
            checkedAt = nil
            // A failed sweep must not leave the last run's rows looking like this one's.
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
        guard !isProvisional else { return nil }
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

    /// The plan intent for the current selection: named targets, not an
    /// identity, so the planner treats it as tidying rather than uninstalling
    /// and does not clear privacy grants or registrations for an app that is
    /// already gone.
    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        guard !isScanning, !isProvisional, canRemoveSelection else { return nil }
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
