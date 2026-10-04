import Foundation

/// Command completion is not a measurement of the cache or freed space.
public struct ToolCleanupResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case completed, failed, notRun }
    public let state: State
    public let command: String
    public let scope: String?
    public let failure: String?

    public var headline: String {
        switch state {
        case .completed: "Command completed"
        case .failed: "Cleanup did not complete"
        case .notRun: "Cleanup has not run"
        }
    }

    public var detail: String {
        switch state {
        case .completed: "The tool finished. Brim has not verified that the cache is empty or measured space freed."
        case .failed: failure ?? "The command failed. It may have removed some cached items."
        case .notRun: "No command outcome was recorded. Nothing has been verified."
        }
    }

    public init(state: State, command: String, scope: String?, failure: String? = nil) {
        self.state = state
        self.command = command
        self.scope = scope
        self.failure = failure
    }
}
