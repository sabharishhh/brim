import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Background section: what macOS runs on your behalf, and what
/// it is still being told to run for software that has gone.
///
/// One load, everything in it. This used to arrive in two stages, because
/// login items came from `sfltool` and cost an administrator prompt, so
/// they waited behind a toggle. They are read from the Background Task
/// Management store now, at the same price as everything else, which is
/// nothing.
@MainActor
public final class BackgroundModel: ObservableObject {

    @Published public private(set) var report: RegistrationReport = .empty
    @Published public private(set) var isLoading = false
    @Published public var searchText = ""
    @Published public var showsSystemOwned = false
    /// Which loose ends are picked for removal, by registration id.
    @Published public var selection: Set<String> = []

    private var service: (any BrimServiceProtocol)?

    public init() {}

    /// Entries pointing at something that has gone and will stay gone
    /// until somebody removes them. Apple ships jobs whose programs are
    /// absent by design, and those are already filtered out.
    public var stale: [RegistrationGroup] {
        RegistrationGroup.group(filtered(report.stale)).filter { !$0.staleClearsItself }
    }

    /// Entries whose owner has gone but which macOS clears by itself.
    ///
    /// Kept apart from the ones that need doing something about, because
    /// putting them together made Brim claim two AppCleaner login items
    /// were left behind when macOS dropped them a couple of minutes later
    /// without being asked.
    public var clearingItself: [RegistrationGroup] {
        RegistrationGroup.group(filtered(report.stale)).filter(\.staleClearsItself)
    }

    /// Entries still pointing at something real.
    public var live: [RegistrationGroup] {
        RegistrationGroup.group(
            filtered(report.live.filter { showsSystemOwned || !$0.isSystemOwned })
        )
    }

    public var hiddenSystemCount: Int {
        showsSystemOwned ? 0 : report.live.filter(\.isSystemOwned).count
    }

    public var gaps: [RegistrationCoverage] { report.gaps }

    // MARK: - Removing what is left over

    /// Everything currently selected.
    public var selectedItems: [Registration] {
        report.stale.filter { selection.contains($0.id) }
    }

    /// Whether this entry is something Brim can actually take away.
    ///
    /// A launchd job is a file: unload it, remove the file, done. A
    /// background item is a row in a database macOS owns, and the only
    /// tool it offers resets every application's items at once, so there
    /// is nothing honest to offer per item. Those clear themselves anyway.
    public static func isRemovable(_ registration: Registration) -> Bool {
        registration.kind == .launchdJob
            && registration.recordPath != nil
            && !registration.isSystemOwned
    }

    public func isSelected(_ group: RegistrationGroup) -> Bool {
        let removable = group.stale.filter(Self.isRemovable)
        return !removable.isEmpty && removable.allSatisfy { selection.contains($0.id) }
    }

    public func canSelect(_ group: RegistrationGroup) -> Bool {
        group.stale.contains(where: Self.isRemovable)
    }

    public func toggle(_ group: RegistrationGroup) {
        let removable = group.stale.filter(Self.isRemovable)
        if isSelected(group) {
            for item in removable { selection.remove(item.id) }
        } else {
            for item in removable { selection.insert(item.id) }
        }
    }

    public var canRemoveSelection: Bool { !selectedItems.isEmpty }

    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        let targets = selectedItems.compactMap(\.recordPath).map { URL(fileURLWithPath: $0) }
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Background jobs"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }

    private func filtered(_ items: [Registration]) -> [Registration] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
                || ($0.programPath?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.recordPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        self.service = service
        guard report.registrations.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }
        report = await service.registrations()
        // Anything that has gone is no longer selectable.
        let present = Set(report.stale.map(\.id))
        selection.formIntersection(present)
    }
}
