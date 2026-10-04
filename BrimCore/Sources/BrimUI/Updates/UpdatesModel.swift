import BrimCore
import BrimProtocol
import Combine
import Foundation

/// Backs the Updates section: which applications have a newer version, and
/// putting it in place.
///
/// A check reaches the network, so it runs when the section opens and the
/// last one is more than six hours old, and when somebody asks. Nothing
/// runs in the background.
@MainActor
public final class UpdatesModel: ObservableObject {
    /// Where one update has got to.
    public enum InstallState: Equatable, Sendable {
        case downloading(Double)
        case installing
        case updated(String)
        case openedInstaller
        case stillOpen(String)
        /// Refused by macOS; the row offers App Management's setting.
        case notAllowed
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .downloading, .installing: true
            default: false
            }
        }
    }

    @Published public private(set) var check: UpdateCheck?
    @Published public private(set) var isChecking = false
    @Published public private(set) var states: [String: InstallState] = [:]
    /// Finished in this session, shown as updated before the next check
    /// sees it on disk.
    @Published private var finished: [RecentUpdate] = []

    /// Updated in the last two weeks, newest first, by any route.
    public var recent: [RecentUpdate] {
        let seen = Set(finished.map(\.id))
        return (finished + (check?.recent ?? []).filter { !seen.contains($0.id) })
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Kept for the window's loading indicator, which watches every section.
    public var isLoading: Bool {
        isChecking
    }

    public init() {}

    private static let staleAfter: TimeInterval = 6 * 3600

    /// Updates not yet put in place. Nil until a check has answered: a
    /// count nobody measured is not zero.
    public var pending: [AppUpdate]? {
        check?.updates.filter { update in
            switch states[update.id] {
            case .updated, .openedInstaller: false
            default: true
            }
        }
    }

    public var count: Int? {
        pending?.count
    }

    /// Updates Brim can put in place without anybody else's window.
    public var installableHere: [AppUpdate] {
        (pending ?? []).filter { $0.route == .replace || $0.route == .homebrew }
    }

    public var isInstalling: Bool {
        states.values.contains(where: \.isBusy)
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        if let check, Date().timeIntervalSince(check.checkedAt) < Self.staleAfter {
            return
        }
        await load(service: service)
    }

    private var checkTask: Task<Void, Never>?

    /// Checks now. Two callers share one check.
    public func load(service: any BrimServiceProtocol) async {
        if let checkTask {
            return await checkTask.value
        }
        let task = Task {
            isChecking = true
            defer { isChecking = false }
            let result = await service.checkForUpdates()
            guard !Task.isCancelled else { return }
            check = result
            // A finished update belongs to the list it was finished in.
            states = states.filter { key, state in state.isBusy && result.updates.contains { $0.id == key } }
            // One an earlier run did not finish is shown as failed, to retry.
            for update in result.updates where states[update.id] == nil {
                if let why = result.interrupted[update.appURL.path] {
                    states[update.id] = .failed(why)
                }
            }
            finished.removeAll { done in result.recent.contains { $0.id == done.id } }
        }
        checkTask = task
        await task.value
        checkTask = nil
    }

    public func install(_ update: AppUpdate, service: any BrimServiceProtocol) async {
        guard states[update.id]?.isBusy != true else { return }
        states[update.id] = update.download == nil ? .installing : .downloading(0)
        let id = update.id
        let outcome = await service.installUpdate(update) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.states[id] else { return }
                states[id] = fraction >= 1 ? .installing : .downloading(fraction)
            }
        }
        switch outcome {
        case let .installed(version):
            states[id] = .updated(version)
            finished.removeAll { $0.id == id }
            finished.append(RecentUpdate(name: update.name, appURL: update.appURL, fromVersion: update.installedVersion,
                                         toVersion: version, updatedAt: Date()))
        case .alreadyCurrent: states[id] = .updated(update.installedVersion)
        case .openedInstaller: states[id] = .openedInstaller
        case let .stillOpen(name): states[id] = .failed("\(name) did not quit.")
        case .notAllowed: states[id] = .notAllowed
        case let .failed(why): states[id] = .failed(why)
        }
    }

    /// After the person has been sent to the setting, the row offers the
    /// update again rather than the refusal.
    public func clearState(of update: AppUpdate) {
        states[update.id] = nil
    }

    /// One at a time: each may quit an application, and several downloads
    /// at once make every row slower.
    public func installAll(service: any BrimServiceProtocol) async {
        for update in installableHere where states[update.id]?.isBusy != true {
            await install(update, service: service)
        }
    }
}
