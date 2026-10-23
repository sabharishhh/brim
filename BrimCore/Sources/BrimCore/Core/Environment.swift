import Foundation

/// The core dependencies, so tests and the app wire up the same logic.
public struct Environment: Sendable {
    public let root: FileSystemRoot
    public let safety: SafetyChecker
    
    public init(root: FileSystemRoot, safety: SafetyChecker) {
        self.root = root
        self.safety = safety
    }
}
