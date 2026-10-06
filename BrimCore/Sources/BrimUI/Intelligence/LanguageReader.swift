import Foundation

/// The on-device model, as Brim uses it: two narrow questions, each
/// answered from text a person could read themselves.
///
/// The app supplies the real one, the only code that imports
/// FoundationModels. Tests supply a stand-in, so the queue, the cache and
/// every failure path are exercised without a model.
public protocol LanguageReader: Sendable {
    func availability() async -> ModelAvailability
    /// Loads the model ahead of a request that is about to come.
    func prewarm() async
    /// What `version` changes, from its section of the release notes.
    func highlights(notes: String, version: String) async throws -> ReleaseHighlights
    /// A few words for each of `lines` (one-based) of an install script,
    /// read with the rest of the script for context.
    func describe(lines: [Int], of script: String) async throws -> [Int: String]
}

/// Whether the model can be asked, and if not, why, in the person's terms.
public enum ModelAvailability: Sendable, Equatable {
    case ready
    /// Apple Intelligence is on and the model is still downloading.
    case preparing
    case appleIntelligenceOff
    /// This Mac cannot run it.
    case notSupported
    /// Switched off in Brim's settings.
    case offInBrim

    public var phrase: String {
        switch self {
        case .ready: "Ready"
        case .preparing: "Getting ready"
        case .appleIntelligenceOff: "Turned off in System Settings"
        case .notSupported: "Not available on this Mac"
        case .offInBrim: "Off"
        }
    }
}

/// Why a request produced nothing. Each one decides what happens next:
/// a rate limit is retried, a refusal is remembered, a timeout is not.
public enum ModelFailure: Error, Sendable, Equatable {
    case unavailable
    case rateLimited
    /// A guardrail or the model declined; asking again gives the same.
    case refused
    /// The output could not be read as the asked-for structure.
    case unreadable
    case tooLong
    case timedOut
    case other
}

public struct ReleaseHighlights: Codable, Sendable, Equatable {
    public let highlights: [String]
    public let fixesSecurity: Bool

    public init(highlights: [String], fixesSecurity: Bool) {
        self.highlights = highlights
        self.fixesSecurity = fixesSecurity
    }
}
