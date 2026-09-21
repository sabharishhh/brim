import Foundation
import BrimCore

/// Background Task Management: login items and background services.
///
/// This is the surface that motivated the product. When an app is removed
/// without deregistering, System Settings goes on listing its background
/// item — often as a bare identifier with no name — and no amount of file
/// deletion clears it.
///
/// Read through `sfltool dumpbtm`, **which asks for administrator access**.
/// macOS puts up "Allow administrator access for sfltool?" with Touch ID the
/// moment it runs.
///
/// That makes this surface unlike every other one: reading it is not free,
/// and running it inside a scan means an authorisation prompt the user did
/// not ask for, seconds after opening the app, naming a tool they have never
/// heard of. So it does not run unless someone asked for it — `.onlyWhenAsked`
/// is the default, and a scan gets an honest "not read" instead of a prompt.
///
/// The dump is injectable so the parsing can be tested against fixtures
/// without invoking anything.
public struct BackgroundItemSurface: RegistrationSurface {

    /// Whether this surface may raise the administrator prompt.
    public enum Elevation: Sendable, Equatable {
        /// Never run `sfltool`. Coverage reports why, and no prompt appears.
        case onlyWhenAsked
        /// The user asked to see background items and is expecting the
        /// prompt, so running it is what they came for.
        case permitted
    }

    public let kind: Registration.Kind = .backgroundItem
    private let elevation: Elevation

    /// Produces the raw BTM dump. Defaults to running `sfltool`.
    private let dump: @Sendable () -> String?
    /// Maps a numeric UID to that account's home directory. Injectable so
    /// the path normalisation can be tested without real accounts.
    private let homeDirectory: @Sendable (uid_t) -> String?

    public init(
        elevation: Elevation = .onlyWhenAsked,
        dump: (@Sendable () -> String?)? = nil,
        homeDirectory: (@Sendable (uid_t) -> String?)? = nil
    ) {
        self.elevation = elevation
        self.dump = dump ?? { Self.runSFLTool() }
        self.homeDirectory = homeDirectory ?? { Self.systemHomeDirectory(for: $0) }
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        guard elevation == .permitted else {
            return .unavailable(
                kind,
                "Background items were not read. macOS requires administrator access to list "
                + "them, and Brim does not ask for that during a scan."
            )
        }
        guard let text = dump(), !text.isEmpty else {
            return .unavailable(kind, "Background items could not be read from sfltool.")
        }
        return .available(kind)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        // Reporting nothing found would be a lie — `coverage` says it was
        // not read, which is a different thing and the reason that method
        // exists.
        guard elevation == .permitted else { return [] }
        guard let text = dump(), !text.isEmpty else { return [] }

        let fm = FileManager.default
        let records = BTMParser().parse(dump: text)

        // Embedded items print a path relative to the app that ships them,
        // and name that app through Parent Identifier. Index the absolute
        // ones so a child can be resolved against its parent instead of
        // against the working directory.
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

            // Only claim staleness from a path we could actually resolve. An
            // item with no URL at all — a background-tasks record — says
            // nothing about whether its owner is present, so it is judged by
            // its parent instead.
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
                    ? "Registered as a background item with macOS" + (record.developerName.map { " by \($0)." } ?? ".")
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

    /// `sfltool` renders a home directory as `/Users/<uid>`, not as the
    /// account name. Taken literally that path does not exist, so a perfectly
    /// healthy login item reads as a leftover — observed with Figma's agent,
    /// printed as `/Users/501/...` while the app sits in the real home.
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

    private static func runSFLTool() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
