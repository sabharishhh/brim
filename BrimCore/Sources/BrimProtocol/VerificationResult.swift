import BrimCore
import Foundation

public struct VerificationResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID {
        planId
    }

    public let planId: UUID
    public let expectedBytes: Int64
    public let recoveredBytes: Int64
    public let success: Bool
    public let reason: String?
    /// Nil in saved results recorded before fresh observation times were kept.
    public let observedAt: Date?

    /// Every path the plan named that is still on disk, re-observed with `lstat`
    /// after the removal, so the lists can drop what went without rescanning.
    public let remainingPaths: Set<String>
    /// Nil in results written before the removal ceiling was reported.
    public let followUpActions: [RemovalFollowUp]?
    /// What was checked and gone, what the app declares it never had, and
    /// what macOS kept. Nil in results written before the report existed.
    public let report: RemovalReport?
    public let toolCleanup: ToolCleanupResult?
    public let packageRecord: PackageRecordResult?
    public let freeSpaceMeasured: Bool?

    /// The paths that went, which is what a list needs to drop a row.
    public func removedPaths(from planned: some Sequence<String>) -> Set<String> {
        Set(planned).subtracting(remainingPaths)
    }

    public init(
        planId: UUID,
        expectedBytes: Int64,
        recoveredBytes: Int64,
        success: Bool,
        reason: String? = nil,
        remainingPaths: Set<String> = [],
        followUpActions: [RemovalFollowUp]? = nil,
        report: RemovalReport? = nil,
        toolCleanup: ToolCleanupResult? = nil,
        packageRecord: PackageRecordResult? = nil,
        freeSpaceMeasured: Bool? = nil,
        observedAt: Date? = nil
    ) {
        self.planId = planId
        self.expectedBytes = expectedBytes
        self.recoveredBytes = recoveredBytes
        self.success = success
        self.reason = reason
        self.observedAt = observedAt
        self.remainingPaths = remainingPaths
        self.followUpActions = followUpActions
        self.report = report
        self.toolCleanup = toolCleanup
        self.packageRecord = packageRecord
        self.freeSpaceMeasured = freeSpaceMeasured
    }
}
