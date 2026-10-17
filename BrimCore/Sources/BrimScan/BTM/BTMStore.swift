import BrimCore
import BrimScanShim
import Foundation

/// Reads Background Task Management from its own store in
/// `/var/db/com.apple.backgroundtaskmanagement`: ordinary mode 644 files that
/// need Full Disk Access and nothing else. `sfltool dumpbtm` raises an
/// administrator prompt that belongs to the tool, not the data. The files
/// are `NSKeyedArchiver` archives, decoded with stand-in classes.
public struct BTMStore: Sendable {
    /// Where macOS keeps it.
    public static let systemDirectory = URL(
        fileURLWithPath: "/var/db/com.apple.backgroundtaskmanagement"
    )

    private let directory: URL
    private let currentUser: @Sendable () -> UUID?

    public init(
        directory: URL = BTMStore.systemDirectory,
        currentUser: (@Sendable () -> UUID?)? = nil
    ) {
        self.directory = directory
        self.currentUser = currentUser ?? { Self.directoryUUID(for: getuid()) }
    }

    /// Every background item for this account and the system. Nil means the
    /// store could not be read, usually because Full Disk Access is off, which
    /// is different from an empty list.
    public struct Read: Sendable {
        public let records: [BTMRecord]
        public let coverage: RegistrationCoverage
        public init(records: [BTMRecord], coverage: RegistrationCoverage) {
            self.records = records
            self.coverage = coverage
        }
    }

    public func records() -> [BTMRecord]? {
        let read = snapshot()
        return read.coverage.scopes?.contains(where: \.available) == true ? read.records : nil
    }

    /// Read records and coverage together. A successful user store cannot
    /// hide a denied or unsupported machine store.
    public func snapshot() -> Read {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            return Read(records: [], coverage: .unavailable(
                .backgroundItem, "Login items and background services could not be read.",
                absence: .needsPermission
            ))
        }
        let user = currentUser()
        let stores = Self.storesToRead(in: files, belongingTo: user)
        var records: [BTMRecord] = []
        var scopes: [RegistrationCoverage.Scope] = []
        if user == nil || !stores.contains(where: {
            Self.parseName($0.lastPathComponent)?.owner == user?.uuidString
        }) {
            scopes.append(.init(namespace: user?.uuidString ?? "current-user",
                                available: false, limitation: "The account store could not be identified."))
        }
        if !stores.contains(where: {
            Self.parseName($0.lastPathComponent)?.owner?.hasPrefix(Self.pseudoAccountPrefix) == true
        }) {
            scopes.append(.init(namespace: "machine", available: false,
                                limitation: "The machine store could not be identified."))
        }
        for store in stores {
            let namespace = Self.parseName(store.lastPathComponent)?.owner ?? store.lastPathComponent
            guard let decoded = Self.decode(store) else {
                scopes.append(.init(namespace: namespace, available: false,
                                    limitation: "The background store could not be decoded."))
                continue
            }
            scopes.append(.init(namespace: namespace, available: true))
            records.append(contentsOf: decoded.map { $0.inStore(store.path, namespace: namespace) })
        }
        let complete = !scopes.isEmpty && scopes.allSatisfy(\.available)
        return Read(records: records, coverage: RegistrationCoverage(
            kind: .backgroundItem, available: complete,
            limitation: complete ? nil : "Part of the background item list could not be checked.",
            scopes: scopes
        ))
    }

    // MARK: - Choosing files

    /// Picks the newest format version, then this account's store within it.
    /// Each account's file is named for the directory UUID `mbr_uid_to_uuid`
    /// returns; other people's stores are left alone, and the
    /// `FFFFEEEE-DDDD-...` names are system pseudo-accounts (uid 0 holds
    /// machine-wide daemons). Older versions stay on disk after an upgrade and
    /// list removed software, so only the highest is read.
    static func storesToRead(in files: [URL], belongingTo user: UUID?) -> [URL] {
        let parsed = files.compactMap { url -> (version: Int, owner: String?, url: URL)? in
            guard let parts = parseName(url.lastPathComponent) else { return nil }
            return (parts.version, parts.owner, url)
        }
        guard let newest = parsed.map(\.version).max() else { return [] }

        return parsed
            .filter { $0.version == newest }
            .filter { candidate in
                guard let owner = candidate.owner else {
                    // The file with no account in its name indexes which accounts have stores.
                    return false
                }
                if owner.hasPrefix(Self.pseudoAccountPrefix) {
                    return true
                }
                return owner == user?.uuidString
            }
            .map(\.url)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let pseudoAccountPrefix = "FFFFEEEE-DDDD-CCCC-BBBB-AAAA"

    /// `BackgroundItems-v18-C995F5A3-….btm` → (18, "C995F5A3-…").
    static func parseName(_ name: String) -> (version: Int, owner: String?)? {
        guard name.hasPrefix("BackgroundItems-v"), name.hasSuffix(".btm") else { return nil }
        let body = name.dropFirst("BackgroundItems-v".count).dropLast(".btm".count)
        guard let separator = body.firstIndex(of: "-") else {
            return Int(body).map { ($0, nil) }
        }
        guard let version = Int(body[body.startIndex ..< separator]) else { return nil }
        return (version, String(body[body.index(after: separator)...]).uppercased())
    }

    /// The directory UUID for a numeric user id, which names the store files.
    /// `mbr_uid_to_uuid` is what macOS itself uses.
    static func directoryUUID(for uid: uid_t) -> UUID? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard brim_uid_to_uuid(uid, &bytes) == 0 else { return nil }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Decoding

    static func decode(_ file: URL) -> [BTMRecord]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        // Unknown classes and missing keys come back as nil instead of raising an
        // exception Swift cannot catch.
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ArchivedUserStore.self, forClassName: "BTMUserStore")
        unarchiver.setClass(ArchivedItem.self, forClassName: "ItemRecord")
        unarchiver.setClass(ArchivedSettings.self, forClassName: "BTMUserSettings")

        let store = unarchiver.decodeObject(of: ArchivedUserStore.self, forKey: "userStore")
        unarchiver.finishDecoding()
        guard let store, unarchiver.error == nil, store.valid else { return nil }
        return store.items.map(\.record)
    }
}

// MARK: - Stand-in classes

/// Stands in for `BTMUserStore` while decoding. It only has to hold the
/// records; everything else in the archive is settings Brim does not read.
@objc(BrimArchivedUserStore)
final class ArchivedUserStore: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool {
        true
    }

    let items: [ArchivedItem]
    let valid: Bool

    init?(coder: NSCoder) {
        let classes: [AnyClass] = [NSArray.self, NSMutableArray.self, ArchivedItem.self]
        let decoded = coder.decodeObject(of: classes, forKey: "records") as? [Any]
        items = decoded?.compactMap { $0 as? ArchivedItem } ?? []
        valid = coder.containsValue(forKey: "records") && decoded != nil
            && items.count == decoded?.count
    }

    func encode(with _: NSCoder) {}
}

/// Unread, but named so the decoder does not have to guess at it.
@objc(BrimArchivedSettings)
final class ArchivedSettings: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool {
        true
    }

    init?(coder _: NSCoder) {}
    func encode(with _: NSCoder) {}
}

/// One `ItemRecord`, which is a login item, a helper, an extension or a
/// background task that some application registered.
@objc(BrimArchivedItem)
final class ArchivedItem: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool {
        true
    }

    let record: BTMRecord

    init?(coder: NSCoder) {
        func string(_ key: String) -> String? {
            guard coder.containsValue(forKey: key) else { return nil }
            let value = coder.decodeObject(of: NSString.self, forKey: key) as String?
            return (value?.isEmpty ?? true) ? nil : value
        }

        let url = coder.decodeObject(of: NSURL.self, forKey: "url") as URL?
        let uuid = coder.decodeObject(of: NSUUID.self, forKey: "uuid") as UUID?

        guard let uuid else { return nil }
        record = BTMRecord(
            uuid: uuid.uuidString,
            name: string("name"),
            developerName: string("developerName"),
            type: BTMDisposition.typeDescription(coder.decodeInteger(forKey: "type")),
            disposition: BTMDisposition.describe(coder.decodeInteger(forKey: "disposition")),
            identifier: string("identifier"),
            rawURLPath: ArchivedItem.path(of: url),
            // The archive calls it the container: the identifier of the item
            // this one is embedded in, which is both what a relative path is
            // relative to and what attributes a helper to its application.
            parentIdentifier: string("container"),
            bundleIdentifier: string("bundleIdentifier"),
            teamIdentifier: string("teamIdentifier"),
            rawType: coder.decodeInteger(forKey: "type"),
            rawDisposition: coder.decodeInteger(forKey: "disposition")
        )
    }

    func encode(with _: NSCoder) {}

    /// An absolute path for a top-level item, a bundle-relative one for an
    /// embedded item. An embedded item is a relative `NSURL` against `file:///`,
    /// so `path` would invent a file at the root of the disk.
    static func path(of url: URL?) -> String? {
        guard let url else { return nil }
        let path = url.baseURL == nil ? url.path : url.relativePath
        return path.isEmpty ? nil : path
    }
}

// MARK: - Bit fields

/// Turns the record's two bit fields into words. Each name was confirmed
/// against records on a real Mac; anything else is reported as its number
/// rather than guessed.
enum BTMDisposition {
    static func typeDescription(_ raw: Int) -> String? {
        guard raw != 0 else { return nil }
        let known: [(Int, String)] = [
            (0x2, "app"),
            (0x4, "login item"),
            (0x8, "agent"),
            (0x10, "daemon"),
            (0x40, "Spotlight importer"),
            (0x80, "Dock tile plugin"),
            (0x800, "extension"),
            (0x2000, "background task")
        ]
        let matched = known.filter { raw & $0.0 != 0 }.map(\.1)
        let accounted = known.filter { raw & $0.0 != 0 }.reduce(0) { $0 | $1.0 }
        let leftover = raw & ~accounted

        if matched.isEmpty {
            return String(format: "type 0x%x", raw)
        }
        if leftover != 0 {
            return matched.joined(separator: ", ") + String(format: " (0x%x)", raw)
        }
        return matched.joined(separator: ", ")
    }

    static func describe(_ raw: Int) -> String? {
        guard raw != 0 else { return "off" }
        let bits: [(Int, String)] = [
            (0x1, "on"),
            (0x2, "allowed"),
            (0x4, "hidden"),
            (0x8, "notified")
        ]
        let matched = bits.filter { raw & $0.0 != 0 }.map(\.1)
        return matched.isEmpty ? String(format: "0x%x", raw) : matched.joined(separator: ", ")
    }

    /// Whether macOS will actually run it. Bit zero of the disposition.
    static func isEnabled(_ raw: Int) -> Bool {
        raw & 0x1 != 0
    }
}
