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

    public init() {}

    /// Updaters still checking for software that is not on this Mac. The
    /// ones worth acting on.
    public var orphaned: [UpdaterAgent] { agents.filter { !$0.productIsInstalled } }
    public var working: [UpdaterAgent] { agents.filter(\.productIsInstalled) }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard agents.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        isLoading = true
        defer { isLoading = false }

        let report = await service.registrations()
        agents = report.registrations.compactMap { registration in
            guard let vendor = UpdaterRecogniser.vendor(for: registration.identifier),
                  !registration.isSystemOwned
            else { return nil }
            return UpdaterAgent(
                registration: registration,
                vendor: vendor,
                // A job whose program has gone cannot be updating anything.
                productIsInstalled: !registration.isStale
            )
        }
        .sorted {
            if $0.productIsInstalled != $1.productIsInstalled { return !$0.productIsInstalled }
            return $0.vendor < $1.vendor
        }
    }
}
