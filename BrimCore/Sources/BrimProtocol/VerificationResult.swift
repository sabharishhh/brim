import Foundation
import BrimCore

public struct VerificationResult: Codable, Equatable, Sendable {
    public let planId: UUID
    public let expectedBytes: Int64
    public let recoveredBytes: Int64
    public let success: Bool
    public let reason: String?
    
    public init(planId: UUID, expectedBytes: Int64, recoveredBytes: Int64, success: Bool, reason: String? = nil) {
        self.planId = planId
        self.expectedBytes = expectedBytes
        self.recoveredBytes = recoveredBytes
        self.success = success
        self.reason = reason
    }
}
