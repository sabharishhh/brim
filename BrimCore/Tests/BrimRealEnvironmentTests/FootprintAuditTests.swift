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
        var identities: [Identity] = []
        for folder in [root.url(for: .applications), root.url(for: .userApplications)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                await identities.append(IdentityResolver(root: root).resolve(bundleURL: folder.appendingPathComponent(name)))
            }
        }
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
            report.append(["app": identity.name, "items": footprint.items.map { $0.evidence.url.path }])
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

        var installed: [Identity] = []
        for folder in [root.url(for: .applications), root.url(for: .userApplications)] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".app") {
                await installed.append(IdentityResolver(root: root).resolve(bundleURL: folder.appendingPathComponent(name)))
            }
        }
        let claimed = installed.map(FootprintAuditTests.tokens(of:))
        let entries = FootprintAuditTests.dataFolderEntries(in: root)
            + ((try? FileManager.default.contentsOfDirectory(atPath: root.url(for: .userCloudKitCaches).path)) ?? [])
            .map { root.url(for: .userCloudKitCaches).appendingPathComponent($0) }
        var misses: [String] = []
        for (id, _) in removed {
            let identity = Identity(bundleID: id, name: names[id.lowercased()] ?? "", recordedNames: aliases[id.lowercased()])
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
