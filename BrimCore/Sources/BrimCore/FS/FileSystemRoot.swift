import Foundation

/// Represents the root of the filesystem to ensure `BrimCore` never uses hardcoded absolute paths.
/// All domain lookups are resolved relative to this root.
public struct FileSystemRoot: Sendable {
    public let rootURL: URL
    
    public init(rootURL: URL = URL(fileURLWithPath: "/")) {
        self.rootURL = rootURL
    }
    
    public enum Domain {
        case userLibrary
        case userPreferences
        case userApplicationSupport
        case userContainers
        case userGroupContainers
        case userLaunchAgents
        case systemLibrary
        case systemLaunchDaemons
        case systemLaunchAgents
        case applications
        case receipts
        case tempDirs
    }
    
    /// Resolves the absolute URL for a given domain relative to this root.
    public func url(for domain: Domain, userName: String = "user") -> URL {
        switch domain {
        case .userLibrary:
            return rootURL.appendingPathComponent("Users/\(userName)/Library")
        case .userPreferences:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Preferences")
        case .userApplicationSupport:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Application Support")
        case .userContainers:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Containers")
        case .userGroupContainers:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Group Containers")
        case .userLaunchAgents:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/LaunchAgents")
        case .systemLibrary:
            return rootURL.appendingPathComponent("Library")
        case .systemLaunchDaemons:
            return rootURL.appendingPathComponent("Library/LaunchDaemons")
        case .systemLaunchAgents:
            return rootURL.appendingPathComponent("Library/LaunchAgents")
        case .applications:
            return rootURL.appendingPathComponent("Applications")
        case .receipts:
            return rootURL.appendingPathComponent("Library/Receipts")
        case .tempDirs:
            return rootURL.appendingPathComponent("private/tmp")
        }
    }
}
