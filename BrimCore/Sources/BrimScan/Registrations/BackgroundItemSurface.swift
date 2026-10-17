import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// Background Task Management: login items and background services. An app
/// removed without deregistering stays listed in System Settings, often as a
/// bare identifier. Read from the store through `BTMStore`, which needs Full
/// Disk Access and raises no prompt. Records are injectable for tests.
public struct BackgroundItemSurface: RegistrationSurface {
    public let kind: Registration.Kind = .backgroundItem

    /// Produces the records. Nil means the store could not be read, which
    /// `coverage` reports as such rather than as an empty list.
    private let readsSystemStore: Bool
    private let read: @Sendable () -> BTMStore.Read
    /// Maps a numeric UID to that account's home directory. Injectable so
    /// the path normalisation can be tested without real accounts.
    private let homeDirectory: @Sendable (uid_t) -> String?

    public init(
        read: (@Sendable () -> [BTMRecord]?)? = nil,
        homeDirectory: (@Sendable (uid_t) -> String?)? = nil
    ) {
        readsSystemStore = read == nil
        if let read {
            self.read = {
                let records = read()
                return BTMStore.Read(records: records ?? [], coverage: records == nil
                    ? .unavailable(.backgroundItem, "Login items and background services could not be read.")
                    : .available(.backgroundItem))
            }
        } else {
            self.read = { BTMStore().snapshot() }
        }
        self.homeDirectory = homeDirectory ?? { Self.systemHomeDirectory(for: $0) }
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        await snapshot(in: root).coverage
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        await snapshot(in: root).registrations
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        if readsSystemStore, root.rootURL.standardizedFileURL.path != "/" {
            return RegistrationSnapshot(registrations: [], coverage: .withheld(
                .backgroundItem, "The system background store is outside this filesystem."
            ))
        }
        let observation = read()
        let records = observation.records
        // IDs repeat between copies and accounts. Only an unambiguous parent
        // in this record's namespace may resolve a relative location.
        let byNamespace = Dictionary(grouping: records) { $0.namespace ?? "fixture" }
        let mapped = records.compactMap { record -> Registration? in
            let candidates = byNamespace[record.namespace ?? "fixture"] ?? []
            let grouped = Dictionary(grouping: candidates.filter { $0.identifier != nil }) {
                $0.identifier!
            }
            let parents = grouped.compactMapValues { values in
                values.count == 1 ? values.first : nil
            }
            let resolved = resolve(record, parents: parents, seen: [])
            guard record.bundleIdentifier != nil || resolved != nil || record.parentIdentifier != nil else {
                return nil
            }
            let presence = PathObservation.observe(resolved?.path, followingLinks: true)
            let owner = Self.rootOwner(of: record, parents: parents)
            let isSystemOwned = Self.isSystemOwned(record, resolved: resolved)
            return Registration(
                kind: .backgroundItem,
                identifier: record.bundleIdentifier ?? record.identifier ?? record.uuid,
                label: record.name ?? record.bundleIdentifier ?? resolved?.lastPathComponent ?? record.uuid,
                owningBundleID: owner,
                programPath: resolved?.path,
                targetExists: presence.isPresent,
                recordPath: record.storePath,
                evidence: presence.isAbsent
                    ? "The background record remains listed, but its target is missing."
                    : "Registered as a background item with macOS"
                    + (record.developerName.map { " by \($0)." } ?? "."),
                isSystemOwned: isSystemOwned,
                signing: (isSystemOwned || !presence.isPresent) ? nil : resolved.map {
                    CodeSignature.state(of: $0, recordedTeam: record.teamIdentifier)
                },
                atLogin: record.type?.contains("login item") == true,
                targetPresence: presence, recordIdentity: record.uuid,
                namespace: record.namespace, runtimeState: record.disposition, rawTargetPath: record.rawURLPath
            )
        }
        return RegistrationSnapshot(registrations: mapped, coverage: observation.coverage, readerVersion: 2)
    }

    private func resolve(_ record: BTMRecord, parents: [String: BTMRecord], seen: Set<String>) -> URL? {
        guard !seen.contains(record.uuid) else { return nil }
        if let absolute = record.url {
            let components = absolute.pathComponents
            if components.count > 2, components[1] == "Users",
               let uid = uid_t(components[2]), homeDirectory(uid) == nil {
                return nil
            }
            return Self.normalizingUserPlaceholder(absolute, homeDirectory: homeDirectory)
        }
        guard let parentID = record.parentIdentifier, let parent = parents[parentID],
              let base = resolve(parent, parents: parents, seen: seen.union([record.uuid])) else { return nil }
        guard let relative = record.rawURLPath else { return base }
        let result = base.appendingPathComponent(relative).standardizedFileURL
        guard result.path.hasPrefix(base.standardizedFileURL.path + "/") else { return nil }
        return result
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

    /// The bundle identifier at the top of the container chain, so an app and
    /// everything it ships make one entry. Guarded against a cycle in a
    /// malformed store.
    static func rootOwner(of record: BTMRecord, parents: [String: BTMRecord]) -> String? {
        var current = record
        var seen: Set<String> = [record.uuid]
        while let parentIdentifier = current.parentIdentifier {
            guard let parent = parents[parentIdentifier], !seen.contains(parent.uuid) else { return nil }
            seen.insert(parent.uuid)
            current = parent
        }
        return current.bundleIdentifier
    }

    /// The store records a home folder as `/Users/<uid>`, which does not exist,
    /// so a healthy login item would read as a leftover.
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

    /// Apple's own background items are not the person's to remove. Any of three
    /// fields may be the only one naming the owner: Stocks' refresh item has
    /// only `4096.com.apple.stocks`.
    static func isSystemOwned(_ record: BTMRecord, resolved: URL?) -> Bool {
        let named = [record.bundleIdentifier, record.identifier, record.parentIdentifier]
        if named.contains(where: { $0.map { bundleIdentifier(in: $0).hasPrefix("com.apple.") } == true }) {
            return true
        }
        guard let path = resolved?.resolvingSymlinksInPath().path else { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// The bundle identifier inside a Background Task Management identifier,
    /// which is prefixed with the record's type (`2.` app, `8192.` background
    /// tasks, `128.` dock tile, `4096.` background refresh). Only a leading run
    /// of digits is stripped.
    static func bundleIdentifier(in identifier: String) -> String {
        guard let dot = identifier.firstIndex(of: "."),
              dot != identifier.startIndex,
              identifier[identifier.startIndex ..< dot].allSatisfy(\.isNumber)
        else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }
}
