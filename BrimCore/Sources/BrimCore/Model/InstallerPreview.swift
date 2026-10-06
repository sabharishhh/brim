import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// What an installer would put on this Mac, read without installing it.
///
/// The question Brim asks after the fact, what did this leave, asked before
/// it: a package's own file list says where every file lands, its scripts
/// say what runs as root while it installs, and an application's bundle says
/// what it will register once it runs. Each row says which of those it came
/// from, because "will install" and "can register" are different promises.
public struct InstallerPreview: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case package
        case diskImage
        case application
    }

    public let source: URL
    public let kind: Kind
    /// The product's name where the installer gives one, else the file's.
    public let name: String
    public let signature: InstallerSignature
    public let apps: [App]
    public let items: [Item]
    public let scripts: [Script]
    /// What an application asks macOS for, read from its `Info.plist`.
    public let permissions: [String]
    /// Whether the application runs in the App Sandbox. Nil when it could
    /// not be read, or when this is not an application.
    public let isSandboxed: Bool?
    /// Frameworks that update the application without the App Store.
    public let updater: String?
    /// Everything the package can install, in bytes, from its own count.
    public let totalBytes: Int64?
    /// What this reading could not see, said plainly.
    public let limits: [String]
    /// The installers inside a disk image.
    public let contents: [InstallerPreview]

    public var id: String {
        source.path
    }

    public init(
        source: URL, kind: Kind, name: String, signature: InstallerSignature, apps: [App] = [],
        items: [Item] = [], scripts: [Script] = [], permissions: [String] = [], isSandboxed: Bool? = nil,
        updater: String? = nil, totalBytes: Int64? = nil, limits: [String] = [], contents: [InstallerPreview] = []
    ) {
        self.source = source
        self.kind = kind
        self.name = name
        self.signature = signature
        self.apps = apps
        self.items = items
        self.scripts = scripts
        self.permissions = permissions
        self.isSandboxed = isSandboxed
        self.updater = updater
        self.totalBytes = totalBytes
        self.limits = limits
        self.contents = contents
    }

    /// An application the installer puts down.
    public struct App: Sendable, Equatable, Identifiable {
        public let name: String
        public let identifier: String?
        public let version: String?
        /// Where it will be, or where it is inside a disk image.
        public let path: String
        /// The version installed now, when this identifier is already here.
        public let replacesVersion: String?
        public let isInstalled: Bool
        /// The app's icon as PNG, taken while a disk image was mounted,
        /// because its bundle is gone once the image is ejected.
        public let icon: Data?

        public var id: String {
            path
        }

        public init(
            name: String, identifier: String?, version: String?, path: String, replacesVersion: String? = nil,
            isInstalled: Bool = false, icon: Data? = nil
        ) {
            self.name = name
            self.identifier = identifier
            self.version = version
            self.path = path
            self.replacesVersion = replacesVersion
            self.isInstalled = isInstalled
            self.icon = icon
        }
    }

    /// How a person reasons about what lands: what runs on its own first,
    /// what plugs into macOS next, plain files last.
    public enum Group: Int, Sendable, Equatable, CaseIterable, Comparable {
        case background
        case systemExtensions
        case commandLine
        case plugIns
        case files

        public var title: String {
            switch self {
            case .background: "Runs in the background"
            case .systemExtensions: "Drivers and system extensions"
            case .commandLine: "Command line tools"
            case .plugIns: "Plug-ins"
            case .files: "Other files"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One thing the installer creates, or that an application declares.
    public struct Item: Sendable, Equatable, Identifiable {
        public let path: String
        public let group: Group
        /// What kind of thing this is, in a few words: "Launch daemon".
        public let what: String
        /// How Brim knows: "From the package's file list".
        public let source: String
        public let bytes: Int64?
        /// Already on this Mac, so the installer replaces it.
        public let exists: Bool

        public var id: String {
            group.title + path
        }

        public init(path: String, group: Group, what: String, source: String, bytes: Int64? = nil,
                    exists: Bool = false) {
            self.path = path
            self.group = group
            self.what = what
            self.source = source
            self.bytes = bytes
            self.exists = exists
        }
    }

    /// A script a package runs while it installs.
    public struct Script: Sendable, Equatable, Identifiable {
        /// `preinstall`, `postinstall` or another name the package gives.
        public let name: String
        public let package: String
        public let runsAsAdministrator: Bool
        /// What its text visibly does, as short phrases. Never a judgement:
        /// a script can do anything its text does not show.
        public let calls: [String]
        public let isText: Bool

        public var id: String {
            package + "/" + name
        }

        public init(name: String, package: String, runsAsAdministrator: Bool, calls: [String], isText: Bool) {
            self.name = name
            self.package = package
            self.runsAsAdministrator = runsAsAdministrator
            self.calls = calls
            self.isText = isText
        }
    }
}

/// Who signed an installer, and what Gatekeeper makes of it.
public struct InstallerSignature: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case notarized
        case apple
        case appStore
        /// Signed with a Developer ID, not notarized.
        case notNotarized
        case unsigned
        /// Gatekeeper said something else, or could not be asked.
        case unknown(String?)
    }

    /// "Developer ID Installer: Example Ltd (ABCDE12345)", as signed.
    public let signer: String?
    public let team: String?
    public let verdict: Verdict

    public init(signer: String?, team: String?, verdict: Verdict) {
        self.signer = signer
        self.team = team
        self.verdict = verdict
    }

    /// The developer's own name, without the certificate's kind or team.
    public var developer: String? {
        guard var name = signer else { return nil }
        if let colon = name.range(of: ": ") {
            name = String(name[colon.upperBound...])
        }
        if let team, name.hasSuffix(" (\(team))") {
            name = String(name.dropLast(team.count + 3))
        }
        return name.isEmpty ? nil : name
    }

    /// Gatekeeper's answer from `spctl --assess -vv`, which writes
    /// `accepted` or `rejected` and then `source=…` on standard error.
    public static func verdict(status: Int32, assessment: String) -> Verdict {
        let source = assessment.split(separator: "\n")
            .first { $0.hasPrefix("source=") }
            .map { String($0.dropFirst("source=".count)) }
        switch source {
        case "Notarized Developer ID": return .notarized
        case "Apple System", "Apple Installer": return .apple
        case "Mac App Store": return .appStore
        case "Unnotarized Developer ID": return .notNotarized
        case "no usable signature": return .unsigned
        default:
            if status == 0, source == "Developer ID" {
                return .notNotarized
            }
            return .unknown(source)
        }
    }
}
