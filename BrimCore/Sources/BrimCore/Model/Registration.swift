import Foundation

// swiftformat:disable wrapMultilineStatementBraces
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
    /// Whether macOS launches this when the person signs in, as its own
    /// record says. Optional so a registration saved before it existed
    /// still decodes.
    ///
    /// Background Task Management keeps a record for every application
    /// that has helpers, pointing at the application's bundle, whether or
    /// not the application itself opens at login. Reading "points at an
    /// app" as "opens at login" put Brim, ChatGPT and seven more under
    /// that heading on a Mac where none of them did.
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

    /// The record's own location is part of the identity. Google Keystone
    /// installs the same job twice, once for the user and once for the
    /// machine, and without the path both copies claimed the same id: one
    /// row in a SwiftUI list, and no way to tell which file was which.
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
        kind == .keychainItem || kind == .shellProfileLine || kind == .backgroundItem
            || kind == .firewallEntry || kind == .systemExtension || kind == .legacyLoginItem
            || kind == .appExtension
            || kind == .configurationProfile
    }

    /// A report-only entry is never a thing to sweep, however stale it
    /// looks. Offering an action that does not exist is worse than not
    /// mentioning it.
    public var isActionable: Bool {
        !isReportOnly && !isSystemOwned
    }

    /// A registration pointing at something no longer on disk.
    public var isStale: Bool {
        targetPresence.isAbsent
    }

    /// Stale *and* something the user could actually act on. The sweep shows
    /// these; a stale system entry is noise the user cannot do anything
    /// about, and presenting it as actionable would be a lie.
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

    /// Whether this entry belongs to the given application.
    ///
    /// Matches on the bundle identifier, then on the program path pointing
    /// inside the app's bundle. Deliberately not a name-substring match: a
    /// registration is removed on evidence of ownership, never on a guess,
    /// which is the same rule the evidence engine follows for files.
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

/// Whether a surface was readable, so the UI can distinguish "nothing found"
/// from "could not look" — Milestone 5's gate requires every feature to
/// report its own gaps.
public struct RegistrationCoverage: Equatable, Sendable, Codable {
    /// Why a surface is not in the list, which decides what the person is
    /// offered about it.
    ///
    /// These were one thing and it produced a wrong screen: the keychain,
    /// which Brim deliberately does not read, appeared under "Part of
    /// this list is missing" with a button offering to open Full Disk
    /// Access. Full Disk Access was already granted, so the banner told
    /// somebody their machine was misconfigured, pointed them at a switch
    /// that was already on, and would have changed nothing if it had not
    /// been. A boundary Brim has chosen is not a gap the person can close.
    public enum Absence: String, Equatable, Sendable, Codable {
        /// A permission the person can grant. Worth interrupting for, and
        /// there is something to press.
        case needsPermission
        /// The mechanism did not answer. Worth saying, nothing to press.
        case couldNotRead
        /// Brim will not read this on purpose. Not a fault, not missing,
        /// and never presented as either.
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
