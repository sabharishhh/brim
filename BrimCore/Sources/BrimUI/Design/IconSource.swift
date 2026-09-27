import Foundation

/// What a row is, as far as its icon is concerned.
public enum ItemKind: String, Sendable, CaseIterable {
    case application
    case loginItem
    case backgroundItem
    case launchAgent
    case launchDaemon
    case privacyPermission
    case appExtension
    case systemExtension
    case launchServicesRecord
    case commandLink
    case folder
    case file

    /// The symbol drawn for a registration that has no application to show.
    public var symbolName: String {
        switch self {
        case .application: "app.dashed"
        case .loginItem: "power"
        case .backgroundItem: "gearshape.2"
        case .launchAgent: "clock.arrow.circlepath"
        case .launchDaemon: "server.rack"
        case .privacyPermission: "hand.raised"
        case .appExtension: "puzzlepiece.extension"
        case .systemExtension: "network"
        case .launchServicesRecord: "arrow.up.forward.app"
        case .commandLink: "link"
        case .folder: "folder"
        case .file: "doc"
        }
    }

    /// A record in a database or a job, rather than a file a person would
    /// recognise from Finder. These get their symbol before Finder's icon,
    /// because Finder would draw every launch agent as the same plist.
    var isRegistration: Bool {
        switch self {
        case .folder, .file, .application: false
        default: true
        }
    }
}

/// Where a row's icon comes from.
public enum IconSource: Equatable, Sendable {
    /// A bundle on the disk, drawn by `NSWorkspace`.
    case bundle(URL)
    /// The icon Brim saved for an application that has since been removed.
    case remembered(bundleID: String)
    /// A symbol for a kind of registration.
    case symbol(ItemKind)
    /// Finder's own icon for a file or folder that exists.
    case finder(URL)
    /// Letters on a colour, when there is no image at all.
    case monogram(Monogram)
}

/// Everything the icon rule needs to know about a row.
public struct IconSubject: Equatable, Sendable {
    public var name: String
    public var kind: ItemKind
    /// The item itself, when it is on the disk.
    public var path: URL?
    /// The application the item belongs to, by name.
    public var ownerName: String?
    public var ownerBundleID: String?
    /// The owner's bundle, when it is still installed.
    public var ownerURL: URL?

    public init(
        name: String, kind: ItemKind, path: URL? = nil,
        ownerName: String? = nil, ownerBundleID: String? = nil, ownerURL: URL? = nil
    ) {
        self.name = name
        self.kind = kind
        self.path = path
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.ownerURL = ownerURL
    }
}

/// One icon rule for every row in the product.
///
/// An icon says what a thing is before its name is read, so nothing is
/// drawn as a bare string. The first match wins:
///
/// 1. The owner application, while it is installed.
/// 2. The owner's icon as Brim saved it, once the owner is gone.
/// 3. The item's own bundle, for a plug-in, driver or other bundle.
/// 4. A symbol for a kind of registration: a login item, a job, a record.
/// 5. Finder's icon for a file or folder that exists.
/// 6. A monogram of the owner, or of the item.
public enum IconResolver {
    /// Extensions whose folder is a bundle with an icon of its own.
    static let bundleExtensions: Set<String> = [
        "app", "bundle", "plugin", "driver", "component", "kext", "prefpane",
        "qlgenerator", "appex", "saver", "mdimporter", "systemextension", "vst", "vst3"
    ]

    public static func source(
        for subject: IconSubject,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        remembered: (String) -> Bool
    ) -> IconSource {
        if let owner = subject.ownerURL, exists(owner) {
            return .bundle(owner)
        }
        if let bundleID = subject.ownerBundleID, remembered(bundleID) {
            return .remembered(bundleID: bundleID)
        }
        let isBundle = subject.path.map { bundleExtensions.contains($0.pathExtension.lowercased()) } ?? false
        if isBundle, let path = subject.path, exists(path) {
            return .bundle(path)
        }
        if subject.kind.isRegistration {
            return .symbol(subject.kind)
        }
        if let path = subject.path, exists(path) {
            return .finder(path)
        }
        return .monogram(Monogram(name: subject.ownerName ?? subject.name))
    }
}
