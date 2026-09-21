import Foundation
import BrimCore

/// Background Task Management: login items and background services.
///
/// This is the surface that motivated the product. When an app is removed
/// without deregistering, System Settings goes on listing its background
/// item, often as a bare identifier with no name, and no amount of file
/// deletion clears it.
///
/// Read straight from the Background Task Management store. That matters
/// more than it sounds: this used to go through `sfltool dumpbtm`, which
/// made macOS ask "Allow administrator access for sfltool?" every single
/// time. The surface grew a whole apparatus for dodging that prompt, and
/// the user still met it whenever they wanted to see their login items.
///
/// `BTMStore` reads the same records out of the files macOS keeps them in,
/// which needs Full Disk Access and nothing else. So this is now an
/// ordinary surface: it runs during a scan like the rest, costs nothing,
/// and asks for nothing.
///
/// The records are injectable so the mapping can be tested against fixtures
/// without a machine that happens to have the right software on it.
public struct BackgroundItemSurface: RegistrationSurface {

    public let kind: Registration.Kind = .backgroundItem

    /// Produces the records. Nil means the store could not be read, which
    /// `coverage` reports as such rather than as an empty list.
    private let read: @Sendable () -> [BTMRecord]?
    /// Maps a numeric UID to that account's home directory. Injectable so
    /// the path normalisation can be tested without real accounts.
    private let homeDirectory: @Sendable (uid_t) -> String?

    public init(
        read: (@Sendable () -> [BTMRecord]?)? = nil,
        homeDirectory: (@Sendable (uid_t) -> String?)? = nil
    ) {
        self.read = read ?? { BTMStore().records() }
        self.homeDirectory = homeDirectory ?? { Self.systemHomeDirectory(for: $0) }
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        guard read() != nil else {
            return .unavailable(
                kind,
                "Login items and background services could not be read. Brim needs Full Disk "
                + "Access to see the list macOS keeps."
            )
        }
        return .available(kind)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        // Reporting nothing found would be a lie. `coverage` says it could
        // not be read, which is a different thing and the reason that
        // method exists.
        guard let records = read() else { return [] }

        let fm = FileManager.default

        // An embedded item records a path relative to the app that ships
        // it, and names that app as its parent. Index the absolute ones so
        // a child can be resolved against its parent rather than against
        // the working directory.
        var absoluteByIdentifier: [String: URL] = [:]
        for record in records {
            if let identifier = record.identifier, let url = record.url {
                absoluteByIdentifier[identifier] = url
            }
        }
        let bundleIDByIdentifier = Dictionary(
            records.compactMap { record -> (String, String)? in
                guard let identifier = record.identifier, let bundleID = record.bundleIdentifier else { return nil }
                return (identifier, bundleID)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return records.compactMap { record -> Registration? in
            let resolved = resolve(record, parents: absoluteByIdentifier)

            // Nothing to attribute or act on: no identity, no location.
            guard record.bundleIdentifier != nil || resolved != nil || record.parentIdentifier != nil else {
                return nil
            }

            // Only claim staleness from a path we could actually resolve.
            // An item with no URL at all, a background-tasks record for
            // instance, says nothing about whether its owner is present, so
            // it is judged by its parent instead.
            let targetExists: Bool
            if let resolved {
                targetExists = fm.fileExists(atPath: resolved.path)
            } else if let parentIdentifier = record.parentIdentifier,
                      let parentURL = absoluteByIdentifier[parentIdentifier] {
                targetExists = fm.fileExists(atPath: parentURL.path)
            } else {
                targetExists = true
            }

            // A helper belongs to the app that ships it, so uninstalling the
            // app clears its login item too.
            let owningBundleID = record.bundleIdentifier
                ?? record.parentIdentifier.flatMap { bundleIDByIdentifier[$0] }

            let label = record.name
                ?? record.bundleIdentifier
                ?? resolved?.lastPathComponent
                ?? record.uuid

            return Registration(
                kind: .backgroundItem,
                identifier: record.bundleIdentifier ?? record.identifier ?? record.uuid,
                label: label,
                owningBundleID: owningBundleID,
                programPath: resolved?.path,
                targetExists: targetExists,
                recordPath: nil,
                evidence: targetExists
                    ? "Registered as a background item with macOS"
                        + (record.developerName.map { " by \($0)." } ?? ".")
                    : "Still listed as a background item, but the application it points to is gone.",
                isSystemOwned: Self.isSystemOwned(record, resolved: resolved)
            )
        }
    }

    /// An absolute URL for a record, resolving an embedded item's relative
    /// path against the bundle of its parent.
    func resolve(_ record: BTMRecord, parents: [String: URL]) -> URL? {
        if let absolute = record.url {
            return Self.normalizingUserPlaceholder(absolute, homeDirectory: homeDirectory)
        }
        guard record.hasRelativeURL,
              let relative = record.rawURLPath,
              let parentIdentifier = record.parentIdentifier,
              let parentURL = parents[parentIdentifier]
        else { return nil }
        return parentURL.appendingPathComponent(relative)
    }

    /// The store records a home directory as `/Users/<uid>`, not as the
    /// account name. Taken literally that path does not exist, so a
    /// perfectly healthy login item reads as a leftover. Seen with Figma's
    /// agent, recorded as `/Users/501/...` while the app sits in the real
    /// home.
    static func normalizingUserPlaceholder(
        _ url: URL,
        homeDirectory: @Sendable (uid_t) -> String?
    ) -> URL {
        let components = url.pathComponents
        // ["/", "Users", "<uid>", ...]
        guard components.count > 2, components[1] == "Users",
              let uid = uid_t(components[2]),
              let home = homeDirectory(uid)
        else { return url }

        let remainder = components.dropFirst(3)
        return remainder.reduce(URL(fileURLWithPath: home)) { $0.appendingPathComponent($1) }
    }

    private static func systemHomeDirectory(for uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// Apple's own background items are not leftovers and are not the user's
    /// to remove, however they look.
    static func isSystemOwned(_ record: BTMRecord, resolved: URL?) -> Bool {
        if let bundleID = record.bundleIdentifier, bundleID.hasPrefix("com.apple.") { return true }
        guard let path = resolved?.resolvingSymlinksInPath().path else { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}
