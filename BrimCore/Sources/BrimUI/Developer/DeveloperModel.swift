import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Developer section.
@MainActor
public final class DeveloperModel: ObservableObject {
    @Published public private(set) var caches: [DeveloperCache] = []
    @Published public private(set) var isScanning = false

    public init() {}

    public var totalBytes: Int64 { caches.reduce(0) { $0 + $1.sizeBytes } }

    /// What comes back on its own, which is the figure worth acting on.
    public var recoverableBytes: Int64 {
        caches.filter { $0.cost != .configured }.reduce(0) { $0 + $1.sizeBytes }
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard caches.isEmpty, !isScanning else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        isScanning = true
        defer { isScanning = false }
        caches = await service.developerCaches()
    }
}
