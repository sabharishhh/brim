import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Updates section.
///
/// Built entirely from the registrations the Background section already
/// reads, so opening it costs nothing extra and the two can never disagree
/// about what is installed.
@MainActor
public final class UpdatesModel: ObservableObject {

    @Published public private(set) var agents: [UpdaterAgent] = []
    @Published public private(set) var isLoading = false
    /// How each application gets its next version. Read from the disk,
    /// so this is populated with the network off and says the same thing.
    @Published public private(set) var report = UpdateReport(
        coverage: [], agents: [], homebrewPresent: false
    )

    public init() {}

    /// Updaters still checking for software that is not on this Mac. The
    /// ones worth acting on.
    public var orphaned: [UpdaterAgent] { agents.filter { !$0.productIsInstalled } }
    public var working: [UpdaterAgent] { agents.filter(\.productIsInstalled) }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard report.coverage.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        isLoading = true
        defer { isLoading = false }

        report = await service.updateReport()
        agents = report.agents
    }

    /// Applications with no route to a new version at all. The finding
    /// this section exists to make: software that stays at whatever
    /// version it is at until somebody notices.
    public var stranded: [UpdateCoverage] { report.withoutAnyUpdateSource }

    /// Applications Homebrew installed, which should be removed with
    /// Homebrew rather than by deleting files underneath it.
    public var homebrewManaged: [UpdateCoverage] {
        report.coverage.filter { $0.homebrewCask != nil }
            .sorted { $0.application.name < $1.application.name }
    }

    // MARK: - Checking, and doing something about it

    /// Updates that actually exist. Empty until somebody presses the
    /// button, because finding out reaches the network.
    @Published public private(set) var available: [AvailableUpdate] = []
    @Published public private(set) var isChecking = false
    @Published public private(set) var hasChecked = false
    /// Bundle identifiers currently being installed.
    @Published public private(set) var installing: Set<String> = []
    @Published public var problem: String?

    /// The line at the top. Says whether there is anything to do, which
    /// is the question somebody opening this section is asking.
    public var headline: String {
        if isChecking { return "Checking for updates…" }
        if !hasChecked {
            let count = report.coverage.filter { !$0.sources.isEmpty }.count
            return "\(count) \(count == 1 ? "application" : "applications") can be checked "
                 + "for updates."
        }
        if available.isEmpty {
            return orphanedCasks.isEmpty
                ? "Everything is up to date."
                : "Everything is up to date. \(orphanedCasks.count) Homebrew "
                + "\(orphanedCasks.count == 1 ? "record refers" : "records refer") to "
                + "software that is not installed."
        }
        let count = available.count
        return "\(count) \(count == 1 ? "update is" : "updates are") available."
    }

    /// Casks Homebrew tracks whose application is gone.
    @Published public private(set) var orphanedCasks: [OrphanedCask] = []

    public func forget(_ cask: OrphanedCask, service: any BrimServiceProtocol) async {
        if let complaint = await service.forgetCask(cask.name) {
            problem = complaint
            return
        }
        problem = nil
        orphanedCasks.removeAll { $0.name == cask.name }
    }

    public func check(service: any BrimServiceProtocol) async {
        isChecking = true
        defer { isChecking = false; hasChecked = true }
        available = await service.checkForUpdates()
        orphanedCasks = await service.orphanedCasks()
    }

    public func install(_ update: AvailableUpdate, service: any BrimServiceProtocol) async {
        installing.insert(update.bundleID)
        defer { installing.remove(update.bundleID) }

        if let complaint = await service.installUpdate(update) {
            problem = complaint
            return
        }
        problem = nil
        available.removeAll { $0.bundleID == update.bundleID }
        await load(service: service)
    }

    public func installAll(service: any BrimServiceProtocol) async {
        for update in available where update.canInstall {
            await install(update, service: service)
        }
    }
}
