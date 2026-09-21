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
        /// One of the many directory-based plug-in surfaces: preference
        /// panes, screen savers, Quick Look generators, Spotlight
        /// importers, Audio Units, Internet plug-ins, Services, Automator
        /// actions, colour pickers, fonts, StartupItems, kernel
        /// extensions. One kind rather than thirteen, because they differ
        /// only in which folder they sit in, and the folder is named in
        /// the row.
        case bundlePlugin
        /// A login item from before Background Task Management, held in a
        /// shared file list.
        case legacyLoginItem
        /// A line a tool appended to a shell profile. Reported, never
        /// edited: silently rewriting somebody's shell configuration is
        /// not acceptable.
        case shellProfileLine
        /// A keychain entry. Reported, never touched.
        case keychainItem

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
            case .bundlePlugin: return "Plug-in"
            case .legacyLoginItem: return "Login item"
            case .shellProfileLine: return "Shell profile line"
            case .keychainItem: return "Keychain item"
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
    /// What signs the code this points at, when Brim looked. Nil where the
    /// question does not arise, such as a record with no path at all.
    public let signing: SigningState?
    /// What it would take to remove the record itself, where the record is
    /// a file. Offering a removal without asking this is what produced an
    /// authorization followed by "2 targets still remain".
    public let capability: Capability

    // The record's own location is part of the identity. Google Keystone
    // installs the same job twice, once for the user and once for the
    // machine, and without the path both copies claimed the same id: one
    // row in a SwiftUI list, and no way to tell which file was which.
    public var id: String { "\(kind.rawValue):\(identifier):\(recordPath ?? "")" }

    /// Whether macOS removes this entry by itself once what it points at is
    /// gone.
    ///
    /// Background Task Management does. `backgroundtaskmanagementd` runs a
    /// garbage collection pass whenever a client asks it for the list, and
    /// drops every record whose application has been deleted. Watched in
    /// its own log: two AppCleaner records removed seconds after System
    /// Settings was opened, and the store written out three seconds later.
    /// So a background item pointing at nothing is a list macOS has not
    /// tidied yet, not something the user has to deal with.
    ///
    /// A launchd job is a file. Nothing collects it, which is why an
    /// uninstall that misses one leaves it forever.
    public var isClearedByMacOS: Bool { kind == .backgroundItem }

    /// Whether Brim will only ever describe this, never act on it.
    ///
    /// Two things are in this class and both for the same reason: acting
    /// would be a worse mistake than leaving them. A keychain entry may
    /// hold a licence the person paid for, and Reset deliberately
    /// preserves licence material. A shell profile is a file somebody
    /// wrote by hand, and editing it silently is not something a cleaning
    /// tool gets to do. Both are shown with their location so the person
    /// can act, which is the whole of Brim's job here.
    public var isReportOnly: Bool {
        kind == .keychainItem || kind == .shellProfileLine
    }

    /// A report-only entry is never a thing to sweep, however stale it
    /// looks. Offering an action that does not exist is worse than not
    /// mentioning it.
    public var isActionable: Bool { !isReportOnly && !isSystemOwned }

    /// A registration pointing at something no longer on disk.
    public var isStale: Bool { !targetExists }

    /// Stale *and* something the user could actually act on. The sweep shows
    /// these; a stale system entry is noise the user cannot do anything
    /// about, and presenting it as actionable would be a lie.
    public var isActionableStale: Bool { isStale && isActionable }

    public init(
        kind: Kind,
        identifier: String,
        label: String,
        owningBundleID: String? = nil,
        programPath: String? = nil,
        targetExists: Bool,
        recordPath: String? = nil,
        evidence: String,
        isSystemOwned: Bool = false,
        signing: SigningState? = nil,
        capability: Capability = .ok
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
        self.signing = signing
        self.capability = capability
    }
}

extension Registration {
    /// What a screen reader should say for this row.
    ///
    /// The view builds a row out of seven separate pieces of text, and
    /// left alone the accessibility tree hands a reader all seven as
    /// unrelated fragments: a name, then a category, then a warning, then
    /// a sentence, then a path, with nothing saying they describe one
    /// thing. Composed here instead, so the row reads as a row.
    ///
    /// The path is deliberately left out and carried as the value instead.
    /// Reading a full filesystem path aloud in the middle of every entry
    /// buries the part that matters, and a reader can ask for the value
    /// when they want it.
    public var spokenDescription: String {
        var parts: [String] = [label, kind.displayName]
        if isSystemOwned { parts.append("belongs to macOS") }
        if isActionableStale {
            parts.append(isClearedByMacOS ? "macOS will drop this" : "points at nothing")
        }
        parts.append(evidence)
        if let signing, signing.isTrouble { parts.append(signing.sentence) }
        return SpokenText.sentences(parts)
    }

    /// The location, for the accessibility value.
    public var spokenLocation: String? { programPath ?? recordPath }

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

/// Whether a surface was readable, so the UI can distinguish "nothing found"
/// from "could not look" — Milestone 5's gate requires every feature to
/// report its own gaps.
public struct RegistrationCoverage: Equatable, Sendable, Codable {
    public let kind: Registration.Kind
    public let available: Bool
    /// Why the surface is unavailable, in the user's terms.
    public let limitation: String?

    public init(kind: Registration.Kind, available: Bool, limitation: String? = nil) {
        self.kind = kind
        self.available = available
        self.limitation = limitation
    }

    public static func available(_ kind: Registration.Kind) -> RegistrationCoverage {
        RegistrationCoverage(kind: kind, available: true)
    }

    public static func unavailable(_ kind: Registration.Kind, _ limitation: String) -> RegistrationCoverage {
        RegistrationCoverage(kind: kind, available: false, limitation: limitation)
    }
}

/// Aggregates the surfaces, the way `EvidenceEngine` aggregates evidence.
