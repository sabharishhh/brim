import Foundation

/// A boundary type that tags filesystem-derived strings to prevent prompt injection.
public struct UntrustedString: Codable, Equatable, Sendable, CustomStringConvertible {
    public let raw: String
    
    public init(_ raw: String) {
        self.raw = raw
    }
    
    public var description: String {
        return "<fs_data>\(raw)</fs_data>"
    }
}
