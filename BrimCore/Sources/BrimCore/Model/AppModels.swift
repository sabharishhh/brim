import Foundation

/// How Brim knows an item belongs to an application, and whether anything
/// else has a claim on it. A, B and C are one scale of confidence. S is not
/// on it: it means something else installed claims the item, so it leaves
/// the selection whatever the confidence was.
public enum EvidenceTier: String, Codable, Equatable, Sendable, CaseIterable {
    /// Shared with something else on this Mac. One way only: it can take an item
    /// out of the default selection and never put one in.
    case S
    /// A direct structural link: the bundle itself, a receipt's file list,
    /// a sandbox container, a path that is the bundle identifier.
    case A
    /// Probable, from how the developer names things.
    case B
    /// A heuristic. Shown, and selected by default only when it is clearly
    /// the application's own name in its own data folders.
    case C

    /// Whether this tier states confidence. S does not, so ranking code must
    /// leave it out rather than sort it to one end.
    public var isConfidence: Bool { self != .S }
}

/// Who a path belongs to, when the path itself says so: the enclosing
/// bundle a person recognises, used by both the sweep and registrations.
public enum EnclosingBundle {

    /// The name of the innermost enclosing bundle, without its extension.
    public static func name(of url: URL) -> String? {
        guard let component = component(of: url) else { return nil }
        return (component as NSString).deletingPathExtension
    }

    /// The bundle's full component, extension included.
    public static func component(of url: URL) -> String? {
        for component in url.pathComponents
        where component.hasSuffix(".app") || component.hasSuffix(".framework") {
            return component
        }
        return nil
    }
}

public struct Evidence: Codable, Equatable, Sendable {
    public let url: URL
    public let tier: EvidenceTier
    public let mechanism: String
    public let humanSentence: String
    
    public init(url: URL, tier: EvidenceTier, mechanism: String, humanSentence: String) {
        self.url = url
        self.tier = tier
        self.mechanism = mechanism
        self.humanSentence = humanSentence
    }
}

/// A protocol defining an abstract discovered Application.
public protocol AppArtifact: Sendable {
    var bundleID: String { get }
    var name: String { get }
    var evidence: [Evidence] { get }
}
