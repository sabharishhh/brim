import Foundation
import Combine
import BrimCore
import BrimProtocol
import BrimPrivileged

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

    /// Brim's privileged daemon, for the jobs that live in a folder
    /// belonging to root. Observed directly rather than through a
    /// container, because a nested ObservableObject publishes nothing.
    public let helper = PrivilegedHelperClient()
    /// What the last privileged removal said, when it refused.
    @Published public private(set) var helperRefusals: [String] = []

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
    ///
    /// The capability is the part that was missing. Two jobs in
    /// `/Library/LaunchAgents` were offered, authorized and then failed,
    /// because that directory belongs to root and nothing had asked
    /// whether the removal could succeed before promising it.
    public static func isRemovable(_ registration: Registration) -> Bool {
        registration.kind == .launchdJob
            && registration.recordPath != nil
            && !registration.isSystemOwned
            && registration.capability == .ok
    }

    /// Something Brim cannot reach itself, but the daemon can once it is
    /// set up. Only the two machine-wide launchd folders qualify, because
    /// those are the only places the daemon will touch.
    public static func needsTheHelper(_ registration: Registration) -> Bool {
        guard registration.kind == .launchdJob,
              !registration.isSystemOwned,
              registration.capability == .needsHelper,
              let path = registration.recordPath
        else { return false }
        return domain(of: path) != nil
    }

    static func domain(of path: String) -> PrivilegedJobRemoval.Domain? {
        let directory = (path as NSString).deletingLastPathComponent
        return PrivilegedJobRemoval.Domain.allCases.first { $0.directory == directory }
    }

    /// Whether this entry can be picked at all, now, given what is set up.
    public func canRemove(_ registration: Registration) -> Bool {
        if Self.isRemovable(registration) { return true }
        return Self.needsTheHelper(registration) && helper.state.canRemove
    }

    /// Jobs that need the daemon and are waiting on it being set up.
    public var waitingOnHelper: [Registration] {
        filtered(report.stale).filter(Self.needsTheHelper)
    }

    /// Hands the privileged ones to the daemon, one at a time, and says
    /// what came back. Each file is moved to a root owned holding folder
    /// rather than deleted, so a mistake can be undone.
    public func removeWithHelper(service: any BrimServiceProtocol) async {
        let targets = selectedItems.filter(Self.needsTheHelper)
        guard !targets.isEmpty else { return }

        var refusals: [String] = []
        for target in targets {
            guard let path = target.recordPath, let domain = Self.domain(of: path) else { continue }
            let name = (path as NSString).lastPathComponent
            if let refusal = await helper.removeDefunctJob(domain: domain, name: name) {
                refusals.append("\(name): \(refusal)")
            }
        }
        helperRefusals = refusals
        await load(service: service)
    }

    /// Entries that are genuinely left over but that Brim cannot remove as
    /// it is running. Surfaced rather than discovered on failure, the same
    /// way the leftovers list handles a container it cannot reach.
    public var blocked: [Registration] {
        filtered(report.stale).filter {
            $0.kind == .launchdJob && !$0.isSystemOwned && $0.capability != .ok
        }
    }

    public func isSelected(_ group: RegistrationGroup) -> Bool {
        let removable = group.stale.filter(canRemove)
        return !removable.isEmpty && removable.allSatisfy { selection.contains($0.id) }
    }

    public func canSelect(_ group: RegistrationGroup) -> Bool {
        group.stale.contains(where: canRemove)
    }

    public func toggle(_ group: RegistrationGroup) {
        let removable = group.stale.filter(canRemove)
        if isSelected(group) {
            for item in removable { selection.remove(item.id) }
        } else {
            for item in removable { selection.insert(item.id) }
        }
    }

    public var canRemoveSelection: Bool { !selectedItems.isEmpty }

    /// Whether the selection needs the daemon rather than the ordinary
    /// removal path. Deliberately all or nothing: a mixed selection would
    /// mean two confirmations for one action.
    public var selectionNeedsHelper: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy(Self.needsTheHelper)
    }

    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        let targets = selectedItems.filter(Self.isRemovable)
            .compactMap(\.recordPath).map { URL(fileURLWithPath: $0) }
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
