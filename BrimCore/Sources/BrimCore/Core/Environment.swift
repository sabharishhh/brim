import Foundation

/// The dependency injection container for BrimCore.
/// This ensures tests and the real app wire up the exact same core logic
/// without hardcoded dependencies.
public struct Environment: Sendable {
    public let root: FileSystemRoot
    public let safety: SafetyChecker
    
    // Future additions:
    // public let database: DatabaseWrapper
    // public let appService: SMAppServiceWrapper
    
    public init(root: FileSystemRoot, safety: SafetyChecker) {
        self.root = root
        self.safety = safety
    }
}
