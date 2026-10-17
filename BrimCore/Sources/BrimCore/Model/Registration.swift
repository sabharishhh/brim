import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// An entry an application leaves in one of macOS's own databases rather
/// than on the file system: a background item, a privacy grant, a login
/// item. Deleting the bundle does not remove these.
public struct Registration: Codable, Equatable, Sendable, Identifiable {
    /// Which macOS mechanism holds the entry. Each maps to a supported way
    /// of removing it; Brim never edits these databases directly.
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        /// Background Task Management: login items and background services.
        case backgroundItem
        /// A launchd agent or daemon.
        case launchdJob
        /// A TCC privacy grant: accessibility, screen recording, and so on.
        case privacyGrant
        /// Launch Services registration: "Open With", URL schemes.
        case firewallEntry
        case configurationProfile
        case launchServices
        /// A PluginKit extension: Finder Sync, Share, Widgets, Quick Look.
        case appExtension
        /// A system or network extension.
        case systemExtension
        /// An installer receipt for a package.
        case installerReceipt
        /// A root-owned helper in /Library/PrivilegedHelperTools.
        case privilegedHelper
        /// The directory-based plug-in surfaces (preference panes, screen savers,
        /// Quick Look generators, Spotlight importers, Audio Units and more). One
        /// kind, because they differ only by folder, which the row names.
        case bundlePlugin
        /// A login item from before Background Task Management, held in a
        /// shared file list.
        case legacyLoginItem
        /// A line a tool appended to a shell profile. Reported, never edited.
        case shellProfileLine
        /// A keychain entry. Reported, never touched.
        case keychainItem

        public var displayName: String {
            switch self {
            case .backgroundItem: "Background item"
            case .launchdJob: "Background job"
            case .privacyGrant: "Privacy grant"
            case .firewallEntry: "Firewall entry"
            case .configurationProfile: "Management profile"
            case .launchServices: "Open With registration"
            case .appExtension: "App extension"
            case .systemExtension: "System extension"
            case .installerReceipt: "Installer receipt"
            case .privilegedHelper: "Privileged helper"
            case .bundlePlugin: "Plug-in"
            case .legacyLoginItem: "Login item"
            case .shellProfileLine: "Shell profile line"
            case .keychainItem: "Keychain item"
            }
        }
    }

    public let kind: Kind
    /// The mechanism's own identifier (a launchd label, bundle id, package
    /// id) and what a removal is scoped to.
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
    /// Nil only in records saved before reliable target observations existed.
    public let observedTarget: PathObservation?
    /// Database record identity and namespace are independent of the bundle ID.
    public let recordIdentity: String?
    public let namespace: String?
    public let runtimeState: String?
    public let rawTargetPath: String?
    public var targetPresence: PathObservation {
        observedTarget ?? .unknown("This saved record has no target observation.")
    }

    /// Where the entry itself is recorded, when it is a file (a launchd
    /// plist). Nil for entries held only in a system database.
    public let recordPath: String?
    /// One sentence naming the mechanism, in the same voice as evidence.
    public let evidence: String
    /// True when macOS owns this entry. Apple ships launchd jobs whose programs
    /// are absent (cryptex-relocated or conditionally installed); they are never
    /// offered for cleanup.
    public let isSystemOwned: Bool
    /// What signs the code this points at, when Brim looked. Nil where the
    /// question does not arise, such as a record with no path at all.
    public let signing: SigningState?
    /// What it would take to remove the record itself, where it is a file, so a
    /// removal is never offered that cannot succeed.
    public let capability: Capability
    /// Whether macOS launches this at sign-in, as its own record says. Optional
    /// for older saves. Background Task Management keeps a record for every app
    /// with helpers whether or not it opens at login, so "points at an app" does
    /// not mean "opens at login".
    public let atLogin: Bool?

    /// A login item, by its record's own type or by the older mechanism.
    public var launchesAtLogin: Bool {
        atLogin == true || kind == .legacyLoginItem
    }

    /// The BTM type alone does not establish whether Settings offers a
    /// foreground Remove control. Route to that list conditionally, without
    /// treating a background switch as an erasure operation.
    public var loginItemsFollowUp: RemovalFollowUp? {
        guard !isSystemOwned, kind == .backgroundItem || kind == .legacyLoginItem else { return nil }
        return .loginItemsSettings
    }

    /// The record's location is part of the identity: the same job can be
    /// installed once for the user and once for the machine.
    public var id: String {
        "\(kind.rawValue):\(namespace ?? ""):\(recordIdentity ?? identifier):\(recordPath ?? programPath ?? "")"
    }

    /// No supported observation guarantees that a stale record will be collected.
    public var isClearedByMacOS: Bool {
        false
    }

    /// A system-wide reset is possible for background items, but Brim never
    /// offers it to remove one application's record.
    public func removalTier(ownerPresent: Bool) -> RemovalTier {
        RemovalTier.forRegistration(kind, ownerPresent: ownerPresent)
    }

    /// Whether Brim only ever describes this. A keychain entry may hold a paid
    /// licence, and a shell profile is a file someone wrote by hand, so acting
    /// on either would be a worse mistake than leaving it. Both are shown with
    /// their location.
    public var isReportOnly: Bool {
        kind == .keychainItem || kind == .shellProfileLine || kind == .backgroundItem
            || kind == .firewallEntry || kind == .systemExtension || kind == .legacyLoginItem
            || kind == .appExtension
            || kind == .configurationProfile
            // macOS's privacy database, which Brim reads and never edits.
            || kind == .privacyGrant
    }

    /// A report-only entry is never swept, however stale it looks.
    public var isActionable: Bool {
        !isReportOnly && !isSystemOwned
    }

    /// A registration pointing at something no longer on disk.
    public var isStale: Bool {
        targetPresence.isAbsent
    }

    /// Stale and something the person could act on. A stale system entry is
    /// noise nobody can do anything about.
    public var isActionableStale: Bool {
        isStale && isActionable
    }

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
        capability: Capability = .ok,
        atLogin: Bool? = nil,
        targetPresence: PathObservation? = nil,
        recordIdentity: String? = nil,
        namespace: String? = nil,
        runtimeState: String? = nil, rawTargetPath: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.label = label
        self.owningBundleID = owningBundleID
        self.programPath = programPath
        observedTarget = targetPresence ?? (targetExists ? .present : .absent)
        self.targetExists = observedTarget != .absent
        self.recordIdentity = recordIdentity
        self.namespace = namespace
        self.runtimeState = runtimeState
        self.rawTargetPath = rawTargetPath
        self.recordPath = recordPath
        self.evidence = evidence
        self.isSystemOwned = isSystemOwned
        self.signing = signing
        self.capability = capability
        self.atLogin = atLogin
    }
}

public extension Registration {
    /// One sentence for VoiceOver, composed so the row reads as one thing rather
    /// than seven fragments. The path is the value, not part of the label.
    var spokenDescription: String {
        var parts: [String] = [label, kind.displayName]
        if isSystemOwned {
            parts.append("belongs to macOS")
        }
        if isStale {
            parts.append("The target is missing")
        }
        parts.append(evidence)
        if let signing, signing.isTrouble {
            parts.append(signing.sentence)
        }
        return SpokenText.sentences(parts)
    }

    /// The location, for the accessibility value.
    var spokenLocation: String? {
        programPath ?? recordPath
    }

    /// Whether this entry belongs to the given application: by bundle
    /// identifier, then by a program path inside the app's bundle. Never by a
    /// name substring; registrations are removed on evidence, not a guess.
    func belongs(to identity: Identity, bundleURL: URL?) -> Bool {
        // Launch Services unregisters one path. Its identifier can also
        // belong to another installed copy, which must keep its own record.
        if [.launchServices, .appExtension, .legacyLoginItem, .firewallEntry].contains(kind),
           let bundleURL, let programPath {
            let target = URL(fileURLWithPath: programPath).resolvingSymlinksInPath().path
            let host = bundleURL.resolvingSymlinksInPath().path
            return target == host || target.hasPrefix(host + "/")
        }
        if kind == .backgroundItem, let bundleURL, let programPath,
           programPath.contains(".app/") || programPath.hasSuffix(".app") {
            let target = URL(fileURLWithPath: programPath).resolvingSymlinksInPath().path
            let host = bundleURL.resolvingSymlinksInPath().path
            return target == host || target.hasPrefix(host + "/")
        }
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

/// Whether a surface was readable, so "nothing found" and "could not look"
/// are told apart.
public struct RegistrationCoverage: Equatable, Sendable, Codable {
    /// Why a surface is not in the list, which decides what the person is
    /// offered. A boundary Brim chose, such as the keychain, is not a gap the
    /// person can close, so it never offers a permission.
    public enum Absence: String, Equatable, Sendable, Codable {
        /// A permission the person can grant: worth asking for, with something to
        /// press.
        case needsPermission
        /// The mechanism did not answer. Worth saying, nothing to press.
        case couldNotRead
        /// Brim does not read this on purpose. Never presented as a fault.
        case byDesign
    }

    public let kind: Registration.Kind
    public let available: Bool
    /// Why the surface is unavailable, in the user's terms.
    public let limitation: String?
    public let absence: Absence?
    /// Each namespace is observed independently. Useful records may survive a partial read.
    public let scopes: [Scope]?
    public struct Scope: Codable, Equatable, Sendable {
        public let namespace: String
        public let available: Bool
        public let limitation: String?
        public init(namespace: String, available: Bool, limitation: String? = nil) {
            self.namespace = namespace
            self.available = available
            self.limitation = limitation
        }
    }

    public init(
        kind: Registration.Kind, available: Bool,
        limitation: String? = nil, absence: Absence? = nil, scopes: [Scope]? = nil
    ) {
        self.kind = kind
        self.available = available
        self.limitation = limitation
        self.scopes = scopes
        self.absence = available ? nil : (absence ?? .couldNotRead)
    }

    /// Whether this is something the person can do something about.
    public var isFixableByTheUser: Bool {
        absence == .needsPermission
    }

    /// Whether this is a fault at all. A deliberate boundary is not.
    public var isAFault: Bool {
        !available && absence != .byDesign
    }

    public static func available(_ kind: Registration.Kind) -> RegistrationCoverage {
        RegistrationCoverage(kind: kind, available: true)
    }

    public static func unavailable(
        _ kind: Registration.Kind, _ limitation: String,
        absence: Absence = .couldNotRead
    ) -> RegistrationCoverage {
        RegistrationCoverage(
            kind: kind, available: false, limitation: limitation, absence: absence
        )
    }

    /// Something Brim has chosen not to read. Stated, never as a problem.
    public static func withheld(
        _ kind: Registration.Kind, _ explanation: String
    ) -> RegistrationCoverage {
        RegistrationCoverage(
            kind: kind, available: false, limitation: explanation, absence: .byDesign
        )
    }
}

// Aggregates the surfaces, the way `EvidenceEngine` aggregates evidence.
