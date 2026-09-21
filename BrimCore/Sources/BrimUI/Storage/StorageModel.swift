import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Storage section.
///
/// Holds two things that must not be added together: what the volumes
/// report about themselves, and what Brim believes it could clear. The
/// first is measured, the second is a claim Brim has to stand behind, and
/// a single "you could free 12 GB" number made of both would be neither.
@MainActor
public final class StorageModel: ObservableObject {

    @Published public private(set) var volumes: [VolumeAccount] = []
    @Published public private(set) var isLoading = false

    /// What Brim has actually found and could remove, taken from the
    /// leftovers scan rather than estimated.
    @Published public private(set) var brimCanClear: Int64 = 0
    @Published public private(set) var brimCanClearCount = 0

    public init() {}

    public var startupVolume: VolumeAccount? {
        volumes.first { $0.url.path == "/" } ?? volumes.first
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard volumes.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        isLoading = true
        defer { isLoading = false }
        volumes = await service.volumes()

        // Taken from the same scan the Leftovers section shows, so the two
        // can never disagree about what is on offer.
        if let leftovers = try? await service.leftovers() {
            brimCanClear = leftovers.reduce(0) { $0 + $1.size }
            brimCanClearCount = leftovers.count
        }
    }
}
