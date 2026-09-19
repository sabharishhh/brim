import Foundation

public enum StepOutcome: String, Codable, Equatable, Sendable {
    case success
    case failed
    case skipped
    case refused
}

public struct Outcome: Codable, Equatable, Sendable {
    public let stepIndex: Int
    public let result: StepOutcome
    public let errorMessage: String?
    
    public init(stepIndex: Int, result: StepOutcome, errorMessage: String? = nil) {
        self.stepIndex = stepIndex
        self.result = result
        self.errorMessage = errorMessage
    }
}

public struct LedgerEntry: Codable, Equatable, Sendable {
    public let planId: UUID
    public let planHash: String
    public let executedAt: Date
    public let outcomes: [Outcome]
    public let recoveredBytes: Int64
    
    public init(planId: UUID, planHash: String, executedAt: Date, outcomes: [Outcome], recoveredBytes: Int64) {
        self.planId = planId
        self.planHash = planHash
        self.executedAt = executedAt
        self.outcomes = outcomes
        self.recoveredBytes = recoveredBytes
    }
}
