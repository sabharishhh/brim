import Foundation
import Combine
import BrimCore
import BrimProtocol
import BrimPrivileged

/// Backs the Background section: what your software runs in the background,
/// and what macOS is still being told to run for software that has gone.
///
/// **Your software, not macOS's.** The section used to carry a switch that
/// added Apple's own registrations to the list. On this Mac that is 1,398
/// rows against 23: 905 launchd jobs, every one of them Apple's, and 484 of
/// the 490 app extensions. None of it can be removed, none of it should be,
/// and none of it is what somebody opens an uninstaller to look at. Turning
/// the switch on beachballed the window, and the list it drew after that was
/// 1,193 rows of `AccessibilitySettingsSearchExtension` and `AVConference`.
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
    @Published public var searchText = "" { didSet { regroup() } }
    /// Which loose ends are picked for removal, by registration id.
    @Published public var selection: Set<String> = []

    /// Entries pointing at something that has gone and will stay gone
    /// until somebody removes them. Apple ships jobs whose programs are
    /// absent by design, and those are already filtered out.
    @Published public private(set) var stale: [RegistrationGroup] = []

    /// Entries whose owner has gone but which macOS clears by itself.
    ///
    /// Kept apart from the ones that need doing something about, because
    /// putting them together made Brim claim two AppCleaner login items
    /// were left behind when macOS dropped them a couple of minutes later
    /// without being asked.
    @Published public private(set) var clearingItself: [RegistrationGroup] = []

    /// Entries still pointing at something real, and belonging to software
    /// somebody installed.
    @Published public private(set) var live: [RegistrationGroup] = []

    private var service: (any BrimServiceProtocol)?

    /// Brim's privileged daemon, for the jobs that live in a folder
    /// belonging to root. Observed directly rather than through a
    /// container, because a nested ObservableObject publishes nothing.
    public let helper = PrivilegedHelperClient()


    public init() {}

    /// Drops the job files a removal proved gone, right now.
    ///
    /// Same reason as the leftovers list: `verify` re-observed every path
    /// and said which survived, so rescanning every registration surface to
    /// rediscover that is work the answer has already been given for. A job
    /// that is still there stays on screen, because it is still there.
    public func forget(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let surviving = report.registrations.filter {
            guard let record = $0.recordPath else { return true }
            return !paths.contains(record)
        }
        guard surviving.count != report.registrations.count else { return }
        report = RegistrationReport(registrations: surviving, coverage: report.coverage)
        selection.formIntersection(Set(report.stale.map(\.id)))
        regroup()
    }

    /// The three lists, worked out once per scan and once per keystroke.
    ///
    /// They were computed properties, and that was the second half of the
    /// freeze. One SwiftUI body pass reads `live` four times and `stale`
    /// three, and each read filtered every registration and regrouped the
    /// survivors from scratch: 12ms each, 73ms a pass, for an answer that
    /// had not changed between the first read and the seventh. Typing in
    /// the search field paid it again on every character. Holding the
    /// answer is what a model is for.
    private func regroup() {
        live = RegistrationGroup.group(matching(report.live.filter { !$0.isSystemOwned }))
        let gone = RegistrationGroup.group(matching(report.stale))
        stale = gone.filter { !$0.staleClearsItself }
        clearingItself = gone.filter(\.staleClearsItself)
        revision &+= 1
    }

    /// What the list animates on. See `LeftoversModel.revision`: a
    /// transaction opened around an async mutation does not reliably reach
    /// SwiftUI, so the view watches a value instead.
    @Published public private(set) var revision = 0

    /// Above this many rows a grouped card list stops being readable and
    /// starts being a wall. Below it the cards earn their space.
    public static let tableThreshold = 200

    /// Whether the list on screen is large enough to want a real table.
    public var needsTable: Bool { live.count >= Self.tableThreshold }

    public var gaps: [RegistrationCoverage] { report.gaps }

    /// Surfaces Brim tried to read and could not. Worth a warning.
    public var faults: [RegistrationCoverage] { report.gaps.filter(\.isAFault) }

    /// Surfaces Brim will not read on purpose. Worth saying once, quietly,
    /// and never as something the person should go and fix.
    public var boundaries: [RegistrationCoverage] {
        report.gaps.filter { $0.absence == .byDesign }
    }

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
        matching(report.stale).filter(Self.needsTheHelper)
    }

    /// Connects the daemon to the service, so a plan containing a
    /// privileged step has something to carry it out. Called whenever the
    /// section loads, because the daemon can be set up or taken away
    /// between one visit and the next.
    public func connectHelper(service: any BrimServiceProtocol) async {
        // Only where the daemon would have something to do. Asking macOS
        // about it on a Mac with no privileged jobs to remove costs an XPC
        // round trip, a signature check, and a background-item notification
        // nobody asked for. `waitingOnHelper` is derived from the scan that
        // has just finished, so by here it is a settled answer.
        guard !waitingOnHelper.isEmpty else {
            await service.usePrivilegedRemover(nil)
            await service.usePrivilegedReceiptForgetter(nil)
            return
        }
        helper.refresh()
        // Before trusting it with anything: an SMAppService daemon stays
        // registered across an application update, so the root process
        // answering can be one an older Brim installed.
        await helper.verifyVersion()
        guard helper.state.canRemove else {
            await service.usePrivilegedRemover(nil)
            await service.usePrivilegedReceiptForgetter(nil)
            return
        }
        let helper = self.helper
        await service.usePrivilegedReceiptForgetter { packageID in
            await helper.forgetReceipt(packageID: packageID)
        }
        await service.usePrivilegedRemover { path in
            guard let domain = await BackgroundModel.domain(of: path) else {
                return "That is not somewhere Brim's helper will touch."
            }
            let name = (path as NSString).lastPathComponent
            return await helper.removeDefunctJob(domain: domain, name: name)
        }
    }

    /// Entries that are genuinely left over but that Brim cannot remove as
    /// it is running. Surfaced rather than discovered on failure, the same
    /// way the leftovers list handles a container it cannot reach.
    public var blocked: [Registration] {
        matching(report.stale).filter {
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

    /// Whether anything picked will go through the privileged daemon, so
    /// the review can say so once rather than per row.
    public var selectionUsesHelper: Bool {
        selectedItems.contains(where: Self.needsTheHelper)
    }

    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        // Everything picked, whoever owns the folder it sits in. The
        // planner decides which steps need the daemon; a person ticking
        // boxes should not have to know the difference.
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
            // `load` connects the helper itself, once it knows whether there
            // is anything for it to do.
            await load(service: service)
        } else {
            await connectHelper(service: service)
        }
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = true
        report = await service.registrations()
        regroup()
        // Anything that has gone is no longer selectable.
        let present = Set(report.stale.map(\.id))
        selection.formIntersection(present)
        isLoading = false

        // After the scan, not before it. Connecting first meant
        // `waitingOnHelper` was always empty at the point the decision was
        // made, so the question "is there privileged work here" could not be
        // answered and macOS was asked about the daemon regardless.
        await connectHelper(service: service)
    }
}
