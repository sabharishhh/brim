import BrimCore
import BrimPrivileged
import BrimProtocol
import Combine
import Foundation

/// Backs the Background section: what the person's software runs in the
/// background, and what macOS still runs for software that is gone. Apple's
/// own registrations are left out: nearly all of the list, none removable.
/// Login items come from the Background Task Management store in the same
/// load as everything else.
@MainActor
public final class BackgroundModel: ObservableObject {
    @Published public private(set) var report: RegistrationReport = .empty
    @Published public private(set) var isLoading = false
    /// A load has finished. Before that, an empty list is not a measured
    /// zero, and Home says it is checking rather than that all is well.
    @Published public private(set) var hasLoaded = false
    @Published public var searchText = "" {
        didSet { regroup() }
    }

    /// Which loose ends are picked for removal, by registration id.
    @Published public var selection: Set<String> = []

    /// Entries pointing at something gone, which stay until someone removes
    /// them. Apple's jobs with absent programs are already filtered out.
    @Published public private(set) var stale: [RegistrationGroup] = []

    /// Legacy grouping input. Collection is never assumed from a missing target.
    @Published public private(set) var clearingItself: [RegistrationGroup] = []

    /// Entries still pointing at something real, and belonging to software
    /// somebody installed.
    @Published public private(set) var live: [RegistrationGroup] = []

    private var service: (any BrimServiceProtocol)?
    private var applications: [InstalledApplication] = []
    private var visibleReport: RegistrationReport = .empty

    /// Administrator cleanup, for jobs in root's folders. Observed directly,
    /// because a nested ObservableObject publishes nothing.
    public let helper = PrivilegedHelperClient()

    public init() {}

    /// Drops the job files a removal proved gone, without rescanning every
    /// surface. A job still there stays on screen.
    public func forget(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let surviving = report.registrations.filter {
            guard let record = $0.recordPath else { return true }
            return !paths.contains(record)
        }
        guard surviving.count != report.registrations.count else { return }
        report = RegistrationReport(registrations: surviving, coverage: report.coverage)
        updateVisibleReport()
        regroup()
    }

    /// The three lists, worked out once per scan and once per keystroke rather
    /// than on every read.
    private func regroup() {
        live = RegistrationGroup.group(matching(visibleReport.live))
        let gone = RegistrationGroup.group(matching(visibleReport.stale))
        stale = gone.filter { !$0.staleClearsItself }
        clearingItself = gone.filter(\.staleClearsItself)
        revision &+= 1
    }

    private func updateVisibleReport() {
        visibleReport = RegistrationReport(
            registrations: BackgroundScope.registrations(report.registrations, applications: applications),
            coverage: report.coverage
        )
        selection.formIntersection(Set(visibleReport.stale.map(\.id)))
    }

    /// What the list animates on: a transaction opened around an async mutation
    /// does not reliably reach SwiftUI, so the view watches a value instead.
    @Published public private(set) var revision = 0

    public var gaps: [RegistrationCoverage] {
        report.gaps
    }

    /// Surfaces Brim tried to read and could not. Worth a warning.
    public var faults: [RegistrationCoverage] {
        report.gaps.filter(\.isAFault)
    }

    // MARK: - Removing what is left over

    /// Everything currently selected.
    public var selectedItems: [Registration] {
        visibleReport.stale.filter { selection.contains($0.id) }
    }

    /// Whether Brim can take this entry away. A launchd job is a file: unload it
    /// and remove it, if the folder allows. A background item is a row in a
    /// database macOS owns, with no per-item removal to offer.
    public static func isRemovable(_ registration: Registration) -> Bool {
        registration.kind == .launchdJob
            && registration.recordPath != nil
            && !registration.isSystemOwned
            && registration.capability == .ok
    }

    /// Something Brim cannot reach itself but administrator cleanup can: only
    /// the two machine-wide launchd folders.
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
        if Self.isRemovable(registration) {
            return true
        }
        return Self.needsTheHelper(registration) && helper.state.canRemove
    }

    /// Jobs that need administrator cleanup, which this copy of Brim may
    /// not include.
    public var waitingOnHelper: [Registration] {
        matching(visibleReport.stale).filter(Self.needsTheHelper)
    }

    /// Refreshes administrator cleanup's state where this section has work for
    /// it. Reading the state starts nothing and asks for no password;
    /// `HelperRoute` connects it to the service once for the app.
    private func refreshHelper() {
        guard !waitingOnHelper.isEmpty else { return }
        helper.refresh()
    }

    /// Entries genuinely left over that Brim cannot remove as it is running,
    /// shown up front rather than found on failure.
    public var blocked: [Registration] {
        matching(visibleReport.stale).filter {
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
            for item in removable {
                selection.remove(item.id)
            }
        } else {
            for item in removable {
                selection.insert(item.id)
            }
        }
    }

    public var canRemoveSelection: Bool {
        !selectedItems.isEmpty
    }

    /// Whether anything picked needs administrator cleanup, so the review says
    /// it once.
    public var selectionUsesHelper: Bool {
        selectedItems.contains(where: Self.needsTheHelper)
    }

    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        // Everything picked, whoever owns its folder. The planner decides which
        // steps need administrator cleanup.
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

    private func matching(_ items: [Registration]) -> [Registration] {
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
        if report.registrations.isEmpty, !isLoading {
            // `load` refreshes administrator cleanup's state once it knows whether
            // there is work for it.
            await load(service: service)
        } else {
            refreshHelper()
        }
    }

    private var loadTask: Task<Void, Never>?

    /// The section owns its scan, so navigation can cancel a waiter without
    /// losing the result. `applications`, when given, is the list Apps already
    /// holds, so the registrations reload without listing every app again.
    public func load(service: any BrimServiceProtocol, applications known: [InstalledApplication]? = nil) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad(service: service, applications: known) }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoad(service: any BrimServiceProtocol, applications known: [InstalledApplication]?) async {
        self.service = service
        isLoading = true
        async let registrationReport = service.registrations()
        if let known {
            applications = known
        } else {
            applications = await (try? service.installedApplications()) ?? []
        }
        report = await registrationReport
        updateVisibleReport()
        regroup()
        isLoading = false
        hasLoaded = true

        // After the scan: before it, `waitingOnHelper` is always empty.
        refreshHelper()
    }
}
