import BrimCore
import BrimIndex
@testable import BrimScan
@testable import BrimService
import XCTest

/// Every installed application's removal, checked against a search that does
/// not use Brim's own rules.
///
/// SystemEQ for Mac's removal left `Application Support/SystemEQ`, and the
/// check afterwards said little was left, because the check asked the same
/// question with the same names as the removal. This search is looser on
/// purpose: any folder at the top of the places applications keep data whose
/// name contains a distinctive part of an application's names or identifier,
/// in any case. Whatever it finds that the removal does not hold, and that
/// no other installed application also answers to, is a miss.
final class FootprintAuditTests: XCTestCase {
    private let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

    func testNothingNamedForAnInstalledApplicationIsLeftOutOfItsRemoval() async throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("BrimAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let service = BrimService(
            root: root, brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: support.appendingPathComponent("Plans"),
            journalStoreDirectory: support.appendingPathComponent("Journals")
        )
        let identities = await Self.installed(in: root)
        let tokens = Dictionary(identities.map { ($0.bundlePath ?? $0.name, Self.tokens(of: $0)) },
                                uniquingKeysWith: { first, _ in first })
        let entries = Self.dataFolderEntries(in: root)
        var report: [[String: Any]] = []
        var misses: [String] = []
        for identity in identities where !(identity.bundleID ?? "").hasPrefix("com.apple.") {
            let own = tokens[identity.bundlePath ?? identity.name] ?? []
            guard !own.isEmpty else { continue }
            let footprint = try await service.inspect(identity: identity)
            let held = footprint.items.map { $0.evidence.url.standardizedFileURL.path.lowercased() }
            for entry in entries {
                let key = NameKey.of(entry.lastPathComponent)
                guard own.contains(where: key.contains) else { continue }
                let path = entry.standardizedFileURL.path.lowercased()
                guard !held.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                let claimants = tokens.filter { $0.key != (identity.bundlePath ?? identity.name) }
                guard !claimants.values.contains(where: { $0.contains(where: key.contains) }) else { continue }
                misses.append("\(identity.name): \(entry.path)")
            }
            report.append(["app": identity.name, "items": footprint.items.map(\.evidence.url.path)])
        }
        if let out = ProcessInfo.processInfo.environment["BRIM_AUDIT_OUT"] {
            try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
                .write(to: URL(fileURLWithPath: out))
        }
        XCTAssertEqual(misses, [], "Named for an installed application and not in its removal:\n"
            + misses.joined(separator: "\n"))
    }

    /// Distinctive parts of what an application is called: its names, the
    /// names without platform words, and the labels of its identifier after
    /// the developer's, as keys of five or more characters that are not
    /// words. The developer's label is left out because it names every
    /// product they make: `com.openai.chat` is the old ChatGPT's, and
    /// `Application Support/OpenAI` holds more than one app's folder.
    static func tokens(of identity: Identity) -> Set<String> {
        let all = (identity.bundleID ?? "").split(separator: ".").map(String.init)
        let labels = Array(all.dropFirst(all.count > 2 ? 2 : 1))
        let words = (identity.ownNames + identity.derivedNames).flatMap { $0.split(separator: " ").map(String.init) }
        let candidates = identity.ownNames + identity.derivedNames + labels + words
        return Set(candidates.filter { NameKey.of($0).count >= 5 && !NameKey.isOrdinaryWord($0) }.map(NameKey.of))
    }

    static func installed(in root: FileSystemRoot) async -> [Identity] {
        var identities: [Identity] = []
        for folder in [root.url(for: .applications), root.url(for: .userApplications)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let bundle = folder.appendingPathComponent(name)
                await identities.append(IdentityResolver(root: root).resolve(bundleURL: bundle))
            }
        }
        return identities
    }

    static func dataFolderEntries(in root: FileSystemRoot) -> [URL] {
        let domains: [FileSystemRoot.Domain] = [
            .userApplicationSupport, .userCaches, .userLogs, .userHTTPStorages, .userWebKit,
            .systemApplicationSupport, .systemCaches, .systemLogs
        ]
        return domains.flatMap { domain -> [URL] in
            let folder = root.url(for: domain)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { !$0.hasPrefix("com.apple.") }.map { folder.appendingPathComponent($0) }
        }
    }
}

/// What removed applications left, checked the same way against the sweep.
/// Reads a copy of Brim's history so the real one is never migrated.
final class LeftoversAuditTests: XCTestCase {
    private let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

    func testWhatARemovedApplicationLeftIsOffered() async throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let store = root.url(for: .userApplicationSupport).appendingPathComponent("Brim/brim.sqlite")
        guard FileManager.default.fileExists(atPath: store.path) else {
            throw XCTSkip("This Mac has no Brim history to read.")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("BrimHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: store.path + suffix) {
            try FileManager.default.copyItem(atPath: store.path + suffix,
                                             toPath: copy.appendingPathComponent("brim.sqlite").path + suffix)
        }
        let index = try Index(dbManager: DatabaseManager(databaseURL: copy.appendingPathComponent("brim.sqlite")))
        let removed = try await index.removedApplications()
        let names = try await index.recordedNames()
        let aliases = try await index.recordedAliases()
        // Whether it is found at all. The sweep holds back for a week what
        // nothing names and something wrote to, which is a separate rule.
        let leftovers = try await LeftoversScanner(root: root, removedApplications: removed)
            .scanLeftovers(knownPastBundleIDs: Set(removed.keys), knownNames: names, knownAliases: aliases)
        let offered = leftovers.map { $0.url.standardizedFileURL.path.lowercased() }

        let claimed = await FootprintAuditTests.installed(in: root).map(FootprintAuditTests.tokens(of:))
        let iCloud = root.url(for: .userCloudKitCaches)
        let entries = FootprintAuditTests.dataFolderEntries(in: root)
            + ((try? FileManager.default.contentsOfDirectory(atPath: iCloud.path)) ?? [])
            .map { iCloud.appendingPathComponent($0) }
        var misses: [String] = []
        for (id, _) in removed {
            let identity = Identity(bundleID: id, name: names[id.lowercased()] ?? "",
                                    recordedNames: aliases[id.lowercased()])
            let own = FootprintAuditTests.tokens(of: identity).union([NameKey.of(id)])
            for entry in entries {
                let key = NameKey.of(entry.lastPathComponent)
                guard own.contains(where: key.contains), !claimed.contains(where: { $0.contains(where: key.contains) })
                else { continue }
                let path = entry.standardizedFileURL.path.lowercased()
                if !offered.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    misses.append("\(identity.name.isEmpty ? id : identity.name): \(entry.path)")
                }
            }
        }
        XCTAssertEqual(misses, [], "Left by a removed application and not offered:\n" + misses.joined(separator: "\n"))
    }
}

/// Nothing Remnants offers belongs to an application that is installed.
///
/// Remnants listed four of ChatGPT's files as removed apps while ChatGPT ran:
/// its folder was opened as a developer's, and Chromium's lock links inside
/// were read as broken commands. Nothing here knows about ChatGPT. Remnants is
/// built as the app builds it, from a copy of Brim's own history, and each
/// installed application's removal is built as its review would be; a row
/// inside one of those, or holding one, contradicts it.
final class InstalledOwnershipAuditTests: XCTestCase {
    func testNoRemnantBelongsToAnInstalledApplication() async throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brim")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("BrimOwners-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["Plans", "Journals", "Ledgers", "brim.sqlite", "brim.sqlite-wal", "brim.sqlite-shm"] {
            let source = real.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: copy.appendingPathComponent(name))
            }
        }
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let service = BrimService(
            root: root, brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: copy.appendingPathComponent("Plans"),
            journalStoreDirectory: copy.appendingPathComponent("Journals")
        )
        let remnants = try await service.leftovers().map { Self.normalized($0.url) }

        var conflicts: [String] = []
        for identity in await FootprintAuditTests.installed(in: root) {
            let owned = try await service.inspect(identity: identity).items.map { Self.normalized($0.evidence.url) }
            for remnant in remnants {
                guard let held = owned.first(where: { Self.overlaps(remnant, $0) }) else { continue }
                conflicts.append("\(remnant) is offered, and \(identity.name) holds \(held)")
            }
        }
        XCTAssertEqual(conflicts, [], "Remnants offers what an installed application holds:\n"
            + conflicts.joined(separator: "\n"))
    }

    /// The same path, or one inside the other.
    static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    /// One spelling per file: lower case, and `/var` as `/private/var`.
    static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.path.lowercased()
        return path.hasPrefix("/var/") ? "/private" + path : path
    }
}
