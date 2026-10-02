import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// A post-removal read, kept apart from execution receipts and declarations.
public struct RegistrationVerification: Codable, Equatable, Sendable, Identifiable {
    public let capability: DeclaredCapability
    public let observedAt: Date
    public let readerVersion: Int
    public let coverage: RegistrationCoverage
    public let remaining: [Registration]
    public let preserved: [Registration]
    public let recoveryCopies: [Registration]?
    public var id: String {
        capability.rawValue
    }

    public init(capability: DeclaredCapability, observedAt: Date, readerVersion: Int = 2,
                coverage: RegistrationCoverage, remaining: [Registration], preserved: [Registration] = [],
                recoveryCopies: [Registration]? = nil) {
        self.capability = capability
        self.observedAt = observedAt
        self.readerVersion = readerVersion
        self.coverage = coverage
        self.remaining = remaining
        self.preserved = preserved
        self.recoveryCopies = recoveryCopies
    }

    public var confirmedClear: Bool {
        hasCompleteCoverage && remaining.isEmpty && preserved.isEmpty && recoveryCopies?.isEmpty != false
    }

    public func confirmsClear(since verificationStartedAt: Date) -> Bool {
        confirmedClear && observedAt >= verificationStartedAt
    }

    public var couldNotCheck: Bool {
        !hasCompleteCoverage && coverage.absence != .byDesign
    }

    public var isReportOnly: Bool {
        !coverage.available && coverage.absence == .byDesign
    }

    private var hasCompleteCoverage: Bool {
        coverage.available && coverage.kind == capability.registrationKind && readerVersion > 0
            && coverage.scopes?.contains(where: { !$0.available }) != true
    }
}
