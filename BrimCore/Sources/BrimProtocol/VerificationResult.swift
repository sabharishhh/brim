import Foundation
import BrimCore

public struct VerificationResult: Codable, Equatable, Sendable {
    public let planId: UUID
    public let expectedBytes: Int64
    public let recoveredBytes: Int64
    public let success: Bool
    public let reason: String?

    /// Every path the plan named that is still on the disk, re-observed with
    /// `lstat` after the removal ran.
    ///
    /// The check has always worked this out and then thrown it away, keeping
    /// only a yes or no and a sentence. That left the screens with nothing
    /// to act on: the leftovers list could not tell which of the rows it had
    /// just removed were actually gone, so it re-scanned the whole Mac to
    /// find out, four hundred milliseconds after the person pressed Done.
    /// The answer was already here.
    public let remainingPaths: Set<String>

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
        remainingPaths: Set<String> = []
    ) {
        self.planId = planId
        self.expectedBytes = expectedBytes
        self.recoveredBytes = recoveredBytes
        self.success = success
        self.reason = reason
        self.remainingPaths = remainingPaths
    }
}
