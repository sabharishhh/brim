import Foundation

/// An entry an application leaves in one of macOS's own databases, rather
/// than on the filesystem.
///
/// These are what survive an ordinary uninstall: the background item still
/// listed in System Settings, the accessibility grant for an app that is
/// gone, the login item pointing at nothing. Deleting the bundle does not
/// remove them, because they do not live in the bundle.
public struct Registration: Codable, Equatable, Sendable, Identifiable {

    /// Which macOS mechanism holds the entry. Each maps to a supported way
    /// of removing it; Brim never edits these databases directly.
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        /// Background Task Management — login items and background services.
        case backgroundItem
        /// A launchd agent or daemon.
        case launchdJob
        /// A TCC privacy grant: accessibility, screen recording, and so on.
        case privacyGrant
        /// Launch Services registration — "Open With", URL schemes.
        case launchServices
        /// A PluginKit extension: Finder Sync, Share, Widgets, Quick Look.
        case appExtension
        /// A system or network extension.
        case systemExtension
        /// An installer receipt for a package.
        case installerReceipt
        /// A root-owned helper in /Library/PrivilegedHelperTools.
        case privilegedHelper

        public var displayName: String {
            switch self {
            case .backgroundItem: return "Background item"
            case .launchdJob: return "Background job"
            case .privacyGrant: return "Privacy grant"
            case .launchServices: return "Open With registration"
            case .appExtension: return "App extension"
            case .systemExtension: return "System extension"
            case .installerReceipt: return "Installer receipt"
            case .privilegedHelper: return "Privileged helper"
            }
        }
    }

    public let kind: Kind
    /// The mechanism's own identifier — a launchd label, bundle id, package
    /// id — and what a removal is scoped to.
    public let identifier: String
    /// What to call this in the UI.
    public let label: String
    /// The bundle identifier this entry belongs to, where one is derivable.
    public let owningBundleID: String?
    /// The file this registration points at, if it names one. A registration
    /// whose program is missing is the classic stale entry.
    public let programPath: String?
    /// False when the registration points at something no longer on disk:
    /// the entry is stale and is exactly what a sweep should surface.
    public let targetExists: Bool
    /// Where the entry itself is recorded, when it is a file (a launchd
    /// plist). Nil for entries held only in a system database.
    public let recordPath: String?
    /// One sentence naming the mechanism, in the same voice as evidence.
    public let evidence: String
    /// True when macOS owns this entry. Apple ships launchd jobs whose
    /// programs are absent — cryptex-relocated or conditionally installed —
    /// and they are neither stale in any useful sense nor removable. They
    /// must never be offered as something to clean up.
    public let isSystemOwned: Bool

    public var id: String { "\(kind.rawValue):\(identifier)" }

    /// A registration pointing at something no longer on disk.
    public var isStale: Bool { !targetExists }

    /// Stale *and* something the user could actually act on. The sweep shows
    /// these; a stale system entry is noise the user cannot do anything
    /// about, and presenting it as actionable would be a lie.
    public var isActionableStale: Bool { isStale && !isSystemOwned }

    public init(
        kind: Kind,
        identifier: String,
        label: String,
        owningBundleID: String? = nil,
        programPath: String? = nil,
        targetExists: Bool,
        recordPath: String? = nil,
        evidence: String,
        isSystemOwned: Bool = false
    ) {
        self.kind = kind
        self.identifier = identifier
        self.label = label
        self.owningBundleID = owningBundleID
        self.programPath = programPath
        self.targetExists = targetExists
        self.recordPath = recordPath
        self.evidence = evidence
        self.isSystemOwned = isSystemOwned
    }
}

extension Registration {
    /// Whether this entry belongs to the given application.
    ///
    /// Matches on the bundle identifier, then on the program path pointing
    /// inside the app's bundle. Deliberately not a name-substring match: a
    /// registration is removed on evidence of ownership, never on a guess,
    /// which is the same rule the evidence engine follows for files.
    public func belongs(to identity: Identity, bundleURL: URL?) -> Bool {
        if let bundleID = identity.bundleID, let owning = owningBundleID, owning == bundleID {
            return true
        }
        if let bundleID = identity.bundleID, identifier == bundleID {
            return true
        }
        if let bundleURL, let programPath {
            let bundlePath = bundleURL.standardizedFileURL.path
            if programPath == bundlePath || programPath.hasPrefix(bundlePath + "/") {
                return true
            }
        }
        return false
    }
}
