import BrimCore
import Foundation

/// The supported runtime operations, injected so filesystem fixtures never
/// send synthetic job names into the person's real launchd namespace.
public struct LaunchdRuntimeClient: Sendable {
    public var stop: @Sendable (String) async throws -> Void
    public var restore: @Sendable (String) async throws -> Void
    public var observe: @Sendable (String, String) async -> PathObservation

    public init(
        stop: @escaping @Sendable (String) async throws
            -> Void = { try await SafeOps.unloadLaunchdJobBounded(path: $0) },
        restore: @escaping @Sendable (String) async throws
            -> Void = { try await SafeOps.loadLaunchdJobBounded(path: $0) },
        observe: @escaping @Sendable (String, String) async -> PathObservation = { await SafeOps.observeLaunchdService(
            label: $0,
            namespace: $1
        ) }
    ) {
        self.stop = stop
        self.restore = restore
        self.observe = observe
    }
}
