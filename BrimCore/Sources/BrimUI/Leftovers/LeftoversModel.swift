import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Leftovers view.
///
/// The two categories are kept apart at every level — separate sections,
/// separate selection, separate totals — because they answer different
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
    @Published public private(set) var errorMessage: String?
    @Published public var searchText = ""

    /// Chosen for removal. Orphans start selected, unclaimed items never do.
    ///
    /// Written only through this model, so there is one place to work the
    /// derived answers out. Every mutation below ends in `settle()`, which
    /// is also why `selectAll` over two hundred and seventy items costs one
    /// pass rather than two hundred and seventy.
    @Published public private(set) var selection: Set<String> = []

    private var service: (any BrimServiceProtocol)?

    public init() {}

    public var all: [Leftover] { orphaned + unclaimed }

    /// One entry per piece of software rather than one per path. The list
    /// was unreadable per-path: the same tool appeared several times with
    /// nothing connecting the rows.
    ///
    /// Published rather than computed. As computed properties these grouped
    /// two hundred and fifty items from scratch on every read, and they are
    /// read several times per body evaluation: once for the summary line,
    /// once per section, and again inside `visible`. Grouping is pure, so the
    /// answer only changes when the arrays do, which is where it is done now.
    @Published public private(set) var orphanedGroups: [LeftoverGroup] = []
    @Published public private(set) var unclaimedGroups: [LeftoverGroup] = []

    /// Which group's detail is open. The list answers "what is here"; the
    /// detail answers "what is this and what do I lose".
    @Published public var inspected: LeftoverGroup?

    public func visible(_ groups: [LeftoverGroup]) -> [LeftoverGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.displayName.localizedCaseInsensitiveContains(query)
                || (group.identifier?.localizedCaseInsensitiveContains(query) ?? false)
                || group.items.contains { $0.url.path.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Selection is per group: a user reasons about software, not paths.
    public func isSelected(_ group: LeftoverGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
    }

    public func toggle(_ group: LeftoverGroup) {
        if isSelected(group) {
            for item in group.items { selection.remove(item.id) }
        } else {
            for item in group.items where item.capability == .ok { selection.insert(item.id) }
        }
        settle()
    }

    public func selectAll(groups: [LeftoverGroup]) {
        for group in groups { for item in group.items where item.capability == .ok { selection.insert(item.id) } }
        settle()
    }

    public func deselectAll(groups: [LeftoverGroup]) {
        for group in groups { for item in group.items { selection.remove(item.id) } }
        settle()
    }

    public func visible(_ items: [Leftover]) -> [Leftover] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    /// What is ticked, and what that comes to.
    ///
    /// These were computed properties reading `all`, which is
    /// `orphaned + unclaimed`: a fresh concatenation of every leftover on
    /// the Mac, then a filter, every time one of them was read. The footer
    /// alone reads them nine times in a single pass, twice through
    /// `canRemoveSelection` and twice more through `blockedSelection`, so
    /// drawing it cost 2.9ms of rebuilding an answer that had not moved.
    /// Worked out when the selection or the scan changes, which is the only
    /// time it can.
    @Published public private(set) var selectedItems: [Leftover] = []
    @Published public private(set) var selectedBytes: Int64 = 0

    /// Items that are selected but that Brim cannot remove as it is running.
    /// Surfaced rather than discovered on failure: a container needs Full
    /// Disk Access, and without it the removal fails in a way that looks
    /// like a defect.
    @Published public private(set) var blockedSelection: [Leftover] = []

    public var canRemoveSelection: Bool {
        !selectedItems.isEmpty && blockedSelection.isEmpty
    }

    /// The one place the selection's consequences are worked out. Called
    /// after a batch of changes, never inside the loop making them.
    private func settle() {
        selectedItems = all.filter { selection.contains($0.id) }
        selectedBytes = selectedItems.reduce(0) { $0 + $1.size }
        blockedSelection = selectedItems.filter { $0.capability != .ok }
    }

    /// Scans only if there is nothing to show. Returning to a section is a
    /// change of view, not a reason to walk the disk again — rescanning is
    /// what the Rescan button is for.
    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard all.isEmpty, !isScanning else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isScanning = true
        defer { isScanning = false }

        do {
            let found = try await service.leftovers()
            orphaned = found.filter { $0.category == .orphaned }
            unclaimed = found.filter { $0.category == .unclaimed }
            orphanedGroups = orphaned.groupedByOwner()
            unclaimedGroups = unclaimed.groupedByOwner()
            // Only orphans are pre-selected, and only the ones Brim can
            // actually act on.
            selection = Set(orphaned.filter { $0.capability == .ok }.map(\.id))
            settle()
            inspected = nil
            errorMessage = nil
        } catch {
            // A failed sweep must not leave the last run's rows on screen
            // looking like this one's answer.
            orphaned = []
            unclaimed = []
            orphanedGroups = []
            unclaimedGroups = []
            selection = []
            settle()
            errorMessage = error.localizedDescription
        }
    }

    public func toggle(_ item: Leftover) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        settle()
    }

    public func selectAll(in items: [Leftover]) {
        for item in items where item.capability == .ok { selection.insert(item.id) }
        settle()
    }

    public func deselectAll(in items: [Leftover]) {
        for item in items { selection.remove(item.id) }
        settle()
    }

    /// The plan intent for the current selection.
    ///
    /// Named targets, not an identity: these items have no owner by
    /// definition, so there is nothing to discover a footprint from. The
    /// planner treats an intent with explicit targets as tidying rather than
    /// uninstalling, which is exactly right — it must not clear privacy
    /// grants or retract registrations for an app that is already gone.
    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Leftovers"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }
}
