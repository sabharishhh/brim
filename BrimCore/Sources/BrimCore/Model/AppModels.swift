import Foundation

/// Represents the level of confidence for a piece of evidence belonging to an app.
/// How Brim knows an item belongs to an application, and whether anything
/// else has a claim on it.
///
/// A, B and C are one scale: how sure Brim is. **S is not on that scale.**
/// S means Shared: something else installed on this Mac also claims this
/// item, so it is removed from the selection whatever the confidence was.
///
/// The letters used to disagree with the specification, and dangerously.
/// `S` meant "cryptographically guaranteed" here and mapped to selected,
/// while T-1.9 and T-3.4 define it as the shared-file veto that may only
/// ever *deselect*. Anybody following the specification and writing
/// `tier: .S` to keep an item out of a plan would have put it in. Nothing
/// emitted `.S`, which is the only reason this never fired.
public enum EvidenceTier: String, Codable, Equatable, Sendable, CaseIterable {
    /// Shared with something else on this Mac, so Brim will not remove it.
    ///
    /// One way only. This tier can take an item out of the default
    /// selection and can never put one in, which is what stops a suite
    /// uninstall taking a component its sibling still needs.
    case S
    /// A direct structural link: the bundle itself, a receipt's file list,
    /// a sandbox container, a path that is the bundle identifier.
    case A
    /// Probable, from how the developer names things.
    case B
    /// A heuristic. Shown, never selected by default.
    case C

    /// Whether this tier is a statement of confidence at all. S is not:
    /// it is a claim about somebody else, and code that ranks or compares
    /// confidence has to leave it out rather than sort it to one end.
    public var isConfidence: Bool { self != .S }
}

/// Represents a single piece of evidence found on disk.
/// Who a path belongs to, when the path itself says so.
///
/// An app extension, a helper, a login item and a broken symlink all live
/// inside somebody's bundle, and that enclosing bundle is the thing a person
/// recognises. `NotificationService` means nothing; `Prime Video` does.
///
/// One implementation, in `BrimCore`, because both the sweep and the
/// registrations list need the same answer and had each grown their own.
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

/// The aggregated result of a filesystem scan.
public struct ScanResult: Sendable {
    public let apps: [any AppArtifact]
    
    public init(apps: [any AppArtifact]) {
        self.apps = apps
    }
}
