import Foundation
import BrimScanShim

/// Reads Background Task Management straight out of its own database.
///
/// Brim used to get this from `sfltool dumpbtm`, and paid for it: macOS puts
/// up "Allow administrator access for sfltool?" every time that runs. The
/// whole surface was built around dodging that prompt, and the user still
/// met it whenever they wanted to see their login items.
///
/// The prompt turns out to be `sfltool`'s, not the data's. The store lives in
/// `/var/db/com.apple.backgroundtaskmanagement` as ordinary files, mode 644,
/// and every field the dump prints is in them. Reading them needs Full Disk
/// Access, which Brim asks for once during setup, and nothing else. No
/// subprocess, no administrator authorisation, no prompt, ever.
///
/// The files are `NSKeyedArchiver` archives, so this decodes them with
/// `NSKeyedUnarchiver` and a set of stand-in classes rather than walking the
/// object graph by hand. Apple's decoder already knows how to follow the
/// references and rebuild the `NSURL`s and `NSUUID`s; hand-resolving `CF$UID`
/// markers would be a second implementation of that, and a worse one.
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

    /// Every background item registered for this account and for the system.
    ///
    /// Nil means the store could not be read, which is a different answer
    /// from an empty list and is reported as such. The usual cause is Full
    /// Disk Access being off.
    public func records() -> [BTMRecord]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        let stores = Self.storesToRead(in: files, belongingTo: currentUser())
        guard !stores.isEmpty else { return nil }

        var records: [BTMRecord] = []
        var readAnything = false
        for store in stores {
            guard let decoded = Self.decode(store) else { continue }
            readAnything = true
            records.append(contentsOf: decoded)
        }
        return readAnything ? records : nil
    }

    // MARK: - Choosing files

    /// Picks the newest format version, then this account's store within it.
    ///
    /// Each account gets its own file, named after the directory UUID that
    /// `mbr_uid_to_uuid` returns for its numeric id. Another person's login
    /// items are neither Brim's business nor removable from here, so their
    /// stores are left alone. The `FFFFEEEE-DDDD-CCCC-BBBB-AAAA…` names are
    /// not people: macOS mints one per system pseudo-account, and the one
    /// for uid 0 is where machine-wide daemons are recorded.
    ///
    /// Old versions stay on disk after an upgrade. This Mac still has a v16
    /// file last written in September, listing software that has since been
    /// removed, so reading anything but the highest version would report
    /// leftovers that are nothing of the kind.
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
                    // The file with no account in its name is an index of
                    // which accounts have stores. It holds no items.
                    return false
                }
                if owner.hasPrefix(Self.pseudoAccountPrefix) { return true }
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
        guard let version = Int(body[body.startIndex..<separator]) else { return nil }
        return (version, String(body[body.index(after: separator)...]).uppercased())
    }

    /// The directory UUID for a numeric user id, which is what names the
    /// store files. `dscl` cannot answer this from a sandboxed process.
    /// `mbr_uid_to_uuid` can, and is what macOS itself uses.
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
        // Unknown classes and missing keys come back as nil rather than as a
        // raised exception, which a Swift caller cannot catch.
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ArchivedUserStore.self, forClassName: "BTMUserStore")
        unarchiver.setClass(ArchivedItem.self, forClassName: "ItemRecord")
        unarchiver.setClass(ArchivedSettings.self, forClassName: "BTMUserSettings")

        let store = unarchiver.decodeObject(of: ArchivedUserStore.self, forKey: "userStore")
        unarchiver.finishDecoding()
        guard let store else { return nil }
        return store.items.map(\.record)
    }
}

// MARK: - Stand-in classes

/// Stands in for `BTMUserStore` while decoding. It only has to hold the
/// records; everything else in the archive is settings Brim does not read.
@objc(BrimArchivedUserStore)
final class ArchivedUserStore: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let items: [ArchivedItem]

    init?(coder: NSCoder) {
        let classes: [AnyClass] = [NSArray.self, NSMutableArray.self, ArchivedItem.self]
        let decoded = coder.decodeObject(of: classes, forKey: "records") as? [Any]
        items = decoded?.compactMap { $0 as? ArchivedItem } ?? []
    }

    func encode(with coder: NSCoder) {}
}

/// Unread, but named so the decoder does not have to guess at it.
@objc(BrimArchivedSettings)
final class ArchivedSettings: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}

/// One `ItemRecord`, which is a login item, a helper, an extension or a
/// background task that some application registered.
@objc(BrimArchivedItem)
final class ArchivedItem: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let record: BTMRecord

    init?(coder: NSCoder) {
        func string(_ key: String) -> String? {
            let value = coder.decodeObject(of: NSString.self, forKey: key) as String?
            return (value?.isEmpty ?? true) ? nil : value
        }

        let url = coder.decodeObject(of: NSURL.self, forKey: "url") as URL?
        let uuid = coder.decodeObject(of: NSUUID.self, forKey: "uuid") as UUID?

        record = BTMRecord(
            uuid: uuid?.uuidString ?? UUID().uuidString,
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
            bundleIdentifier: string("bundleIdentifier")
        )
    }

    func encode(with coder: NSCoder) {}

    /// An absolute path for a top-level item, a bundle-relative one for an
    /// embedded item, matching what `BTMRecord` has always expected.
    ///
    /// An embedded item is stored as a relative `NSURL` against a `file:///`
    /// base, so asking for `path` would hand back `/Contents/Library/…` and
    /// invent a file at the root of the disk. Every one of those would read
    /// as a leftover.
    static func path(of url: URL?) -> String? {
        guard let url else { return nil }
        let path = url.baseURL == nil ? url.path : url.relativePath
        return path.isEmpty ? nil : path
    }
}

// MARK: - Bit fields

/// Turns the two bit fields in a record into words.
///
/// The names for `app`, `login item`, `extension`, `Spotlight importer`,
/// `Dock tile plugin` and `background task` were each confirmed against
/// records on a real Mac whose software was known. `agent` and `daemon` are
/// the values `sfltool` prints for launchd jobs. Anything else is reported
/// as its number rather than guessed at, because a wrong label here would
/// be read as a fact about the user's Mac.
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

        if matched.isEmpty { return String(format: "type 0x%x", raw) }
        if leftover != 0 { return matched.joined(separator: ", ") + String(format: " (0x%x)", raw) }
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
    static func isEnabled(_ raw: Int) -> Bool { raw & 0x1 != 0 }
}
