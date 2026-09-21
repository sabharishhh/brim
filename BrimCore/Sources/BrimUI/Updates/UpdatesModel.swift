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
}
