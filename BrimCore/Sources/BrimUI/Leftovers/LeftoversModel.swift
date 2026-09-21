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
    @Published public var selection: Set<String> = []

    private var service: (any BrimServiceProtocol)?

    public init() {}

    public var all: [Leftover] { orphaned + unclaimed }

    public func visible(_ items: [Leftover]) -> [Leftover] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    public var selectedItems: [Leftover] {
        all.filter { selection.contains($0.id) }
    }

    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    /// Items that are selected but that Brim cannot remove as it is running.
    /// Surfaced rather than discovered on failure: a container needs Full
    /// Disk Access, and without it the removal fails in a way that looks
    /// like a defect.
    public var blockedSelection: [Leftover] {
        selectedItems.filter { $0.capability != .ok }
    }

    public var canRemoveSelection: Bool {
        !selectedItems.isEmpty && blockedSelection.isEmpty
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
            // Only orphans are pre-selected, and only the ones Brim can
            // actually act on.
            selection = Set(orphaned.filter { $0.capability == .ok }.map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggle(_ item: Leftover) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    public func selectAll(in items: [Leftover]) {
        for item in items where item.capability == .ok { selection.insert(item.id) }
    }

    public func deselectAll(in items: [Leftover]) {
        for item in items { selection.remove(item.id) }
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
