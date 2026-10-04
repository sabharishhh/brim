import BrimCore
import Foundation

/// Runtime commands stay injectable, including reads of reviewed job provenance.
public struct LaunchdRuntimeClient: Sendable {
    public var stop: @Sendable (String) async throws -> Void
    public var stopWithReceipt: @Sendable (String) async throws -> Bool
    public var restore: @Sendable (String) async throws -> Void
    public var observe: @Sendable (String, String) async -> PathObservation
    public var observeReviewed: @Sendable (Registration) async -> PathObservation

    public init(
        stop: (@Sendable (String) async throws -> Void)? = nil,
        restore: @escaping @Sendable (String) async throws -> Void = {
            try await SafeOps.loadLaunchdJobBounded(path: $0)
        },
        observe: (@Sendable (String, String) async -> PathObservation)? = nil,
        observeReviewed: (@Sendable (Registration) async -> PathObservation)? = nil,
        stopWithReceipt: (@Sendable (String) async throws -> Bool)? = nil
    ) {
        self.stop = stop ?? { _ = try await SafeOps.unloadLaunchdJobBounded(path: $0) }
        self.stopWithReceipt = stopWithReceipt ?? { path in
            if let stop {
                try await stop(path)
                return true
            }
            return try await SafeOps.unloadLaunchdJobBounded(path: path)
        }
        self.restore = restore
        self.observe = observe ?? { await SafeOps.observeLaunchdService(label: $0, namespace: $1) }
        self.observeReviewed = observeReviewed ?? { record in
            if let observe {
                guard let namespace = record.namespace else {
                    return .unknown("The reviewed background job has no namespace.")
                }
                return await observe(record.identifier, namespace)
            }
            return await SafeOps.observeLoadedReviewedJob(record)
        }
    }
}
