import BrimCore
@testable import BrimScan
import Darwin
import Foundation
import Testing

struct ContainerOwnershipTests {
    @Test func `a shared library xattr claimant protects conflicting container records`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let own = try fixture.app("Sample", identifier: "org.example.sample")
        let other = try fixture.app("Other", identifier: "org.example.other")
        let info = other.appendingPathComponent("Contents/Frameworks/Shared.framework/Resources/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "net.shared.widget"],
                                           format: .xml, options: 0).write(to: info)
        let container = try fixture.container(
            "org.example.sample",
            xattr: "net.shared.widget",
            plist: "org.example.sample"
        )
        let identity = Identity(bundleID: "org.example.sample", name: "Sample", bundlePath: own.path)
        let footprint = try await FootprintProjector(engine: .standard).project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        let row = try #require(evaluated.items.first {
            EvidenceEngine.identity(of: $0.footprintItem.evidence.url) == EvidenceEngine.identity(of: container)
        })
        guard case .excluded = row.selection
        else { Issue.record("A recorded library helper is a live claimant."); return }
        try FileManager.default.removeItem(at: own)
        let leftovers = try await LeftoversScanner(root: fixture.root, hasFullDiskAccess: true)
            .scanLeftovers(knownPastBundleIDs: ["org.example.sample"])
        #expect(!leftovers.contains { EvidenceEngine.identity(of: $0.url) == EvidenceEngine.identity(of: container) })
    }

    @Test func `uncertain metadata cannot bypass the surviving copy veto`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", identifier: "org.example.sample")
        _ = try fixture.app("Copy", identifier: "org.example.sample")
        let container = try fixture.container(UUID().uuidString, xattr: "net.shared.widget", plist: "net.other.widget")
        let identity = Identity(bundleID: "org.example.sample", name: "Sample", bundlePath: app.path)
        let item = FootprintItem(evidence: Evidence(url: container, tier: .C, mechanism: "SandboxContainerSource",
                                                    humanSentence: "Container ownership records disagree."),
                                 sizeBytes: 1, capability: .ok)
        let footprint = EvaluatedFootprint(identity: identity,
                                           items: [EvaluatedItem(
                                               footprintItem: item,
                                               selection: .unselected,
                                               costOfError: .medium
                                           )])
        let vetted = await TierSVetoEngine(root: fixture.root).applyVeto(to: footprint)
        let row = try #require(vetted.items.first)
        guard case .excluded = row.selection
        else { Issue.record("Uncertain metadata cannot bypass a surviving copy veto."); return }
    }

    @Test func `refused installed owner metadata leaves a claimant gap`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Other", identifier: "org.example.other")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: info.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: info.path) }
        let target = fixture.folder.appendingPathComponent("cache")
        try Data([1]).write(to: target)
        let item = FootprintItem(evidence: Evidence(url: target, tier: .A, mechanism: "DirectTarget",
                                                    humanSentence: "Selected cache."), sizeBytes: 1, capability: .ok)
        let footprint = EvaluatedFootprint(identity: Identity(bundleID: "org.example.sample", name: "Sample"),
                                           items: [EvaluatedItem(
                                               footprintItem: item,
                                               selection: .selected,
                                               costOfError: .low
                                           )])
        let vetted = await TierSVetoEngine(root: fixture.root).applyVeto(to: footprint)
        #expect(!vetted.completeness.isComplete)
        #expect(vetted.items.first?.selection == .unselected)
    }

    @Test func `uninstall and Remnants agree on UUID container ownership`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let identifier = "org.example.sample"
        let paths = try [
            fixture.container(identifier),
            fixture.container(UUID().uuidString, xattr: identifier),
            fixture.container(UUID().uuidString, plist: identifier)
        ]
        let identity = Identity(bundleID: identifier, name: "Sample")
        let findings = await SandboxContainerSource().scan(for: identity, in: fixture.root)
        #expect(Set(findings.evidence.map { EvidenceEngine.identity(of: $0.url) }) ==
            Set(paths.map { EvidenceEngine.identity(of: $0) }))
        #expect(findings.completeness.isComplete)
        let leftovers = try await LeftoversScanner(root: fixture.root, hasFullDiskAccess: true)
            .scanLeftovers(knownPastBundleIDs: [identifier])
        #expect(Set(leftovers.filter { $0.category == .orphaned }.map { EvidenceEngine.identity(of: $0.url) })
            == Set(paths.map { EvidenceEngine.identity(of: $0) }))
        #expect(leftovers.allSatisfy { $0.potentialOwner?.bundleID == identifier })
    }

    @Test func `conflicting container metadata never selects itself`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let path = try fixture.container("org.example.sample", xattr: "org.example.other",
                                         plist: "org.example.sample")
        let identity = Identity(bundleID: "org.example.sample", name: "Sample")
        let footprint = try await FootprintProjector(engine: .standard).project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        let row = try #require(evaluated.items
            .first { EvidenceEngine.identity(of: $0.footprintItem.evidence.url) == EvidenceEngine.identity(of: path) })
        #expect(row.selection != .selected)
        let leftovers = try await LeftoversScanner(root: fixture.root, hasFullDiskAccess: true)
            .scanLeftovers(knownPastBundleIDs: ["org.example.sample"])
        #expect(leftovers.first { EvidenceEngine.identity(of: $0.url) == EvidenceEngine.identity(of: path) }?
            .category == .unclaimed)
    }

    @Test func `a live claimant protects a conflicting UUID container`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let path = try fixture.container(UUID().uuidString, xattr: "org.example.sample", plist: "org.example.other")
        let own = try fixture.app("Sample", identifier: "org.example.sample")
        _ = try fixture.app("Other", identifier: "org.example.other")
        let identity = Identity(bundleID: "org.example.sample", name: "Sample", bundlePath: own.path)
        let footprint = try await FootprintProjector(engine: .standard).project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        let row = try #require(evaluated.items
            .first { EvidenceEngine.identity(of: $0.footprintItem.evidence.url) == EvidenceEngine.identity(of: path) })
        guard case .excluded = row.selection else { Issue.record("A live claimant must veto the container."); return }
        let leftovers = try await LeftoversScanner(root: fixture.root, hasFullDiskAccess: true)
            .scanLeftovers(knownPastBundleIDs: ["org.example.sample"])
        #expect(!leftovers.contains { EvidenceEngine.identity(of: $0.url) == EvidenceEngine.identity(of: path) })
    }

    @Test func `refused malformed and oversized metadata remain uncertain`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let path = try fixture.container("org.example.sample", plist: "org.example.sample")
        let metadata = path.appendingPathComponent(ContainerOwnershipReader.metadataName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
        let identity = Identity(bundleID: "org.example.sample", name: "Sample")
        let refused = await SandboxContainerSource().scan(for: identity, in: fixture.root)
        #expect(refused.completeness.unreadable.contains(metadata.resolvingSymlinksInPath().path))
        #expect(refused.evidence.first?.tier == .C)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        try Data("invalid plist".utf8).write(to: metadata)
        #expect(ContainerOwnershipReader.read(at: path).identifier == nil)
        try Data(repeating: 0, count: 70 * 1024).write(to: metadata)
        #expect(ContainerOwnershipReader.read(at: path).identifier == nil)
        let cancelled = await SandboxContainerSource(budget: { ScanBudget(total: -1) }).scan(
            for: identity,
            in: fixture.root
        )
        #expect(!cancelled.completeness.timedOut.isEmpty)
        #expect(cancelled.evidence.isEmpty)
    }
}

struct OwnershipLocationTests {
    @Test func `dictionary metadata and exact system script identifiers agree in both directions`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", identifier: "org.example.sample")
        let identity = Identity(bundleID: "org.example.sample", name: "Sample", bundlePath: app.path)
        let script = fixture.root.url(for: .systemApplicationScripts).appendingPathComponent("org.example.sample")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        try Data([1]).write(to: script.appendingPathComponent("script.scpt"))
        let dictionary = try fixture.dictionary(
            "Words",
            identifier: "org.example.sample.dictionary",
            domain: .userDictionaries
        )
        let unrelated = try fixture.dictionary("Sample", identifier: "net.other.dictionary", domain: .userDictionaries)
        let evidence = try await LocationInventorySource().evidence(for: identity, in: fixture.root)
        let expected = Set([script, dictionary].map { EvidenceEngine.identity(of: $0) })
        #expect(expected.isSubset(of: Set(evidence.map { EvidenceEngine.identity(of: $0.url) })))
        #expect(!evidence.contains { EvidenceEngine.identity(of: $0.url) == EvidenceEngine.identity(of: unrelated) })
        let installed = try await LeftoversScanner(root: fixture.root).scanLeftovers()
        #expect(expected.isDisjoint(with: installed.map { EvidenceEngine.identity(of: $0.url) }))
        try FileManager.default.removeItem(at: app)
        let removed = try await LeftoversScanner(root: fixture.root)
            .scanLeftovers(knownPastBundleIDs: ["org.example.sample"])
        #expect(expected
            .isSubset(of: Set(removed.filter { $0.category == .orphaned }.map { EvidenceEngine.identity(of: $0.url) })))
    }

    @Test func `a surviving copy vetoes dictionaries and system application scripts`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", identifier: "org.example.sample")
        _ = try fixture.app("Copy", identifier: "org.example.sample")
        let dictionary = try fixture.dictionary(
            "Words",
            identifier: "org.example.sample.dictionary",
            domain: .userDictionaries
        )
        let script = fixture.root.url(for: .systemApplicationScripts).appendingPathComponent("org.example.sample")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        let identity = Identity(bundleID: "org.example.sample", name: "Sample", bundlePath: app.path)
        let footprint = try await FootprintProjector(engine: .standard).project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        for path in [dictionary, script] {
            let row = try #require(evaluated.items
                .first {
                    EvidenceEngine.identity(of: $0.footprintItem.evidence.url) == EvidenceEngine.identity(of: path)
                })
            guard case .excluded = row.selection
            else { Issue.record("A surviving copy must veto shared state."); continue }
        }
    }

    @Test func `refused dictionary and application script roots leave scan gaps`() async throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let domains: [FileSystemRoot.Domain] = [.userDictionaries, .systemApplicationScripts]
        for domain in domains {
            let directory = fixture.root.url(for: domain)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        }
        defer {
            for domain in domains {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: fixture.root.url(for: domain).path
                )
            }
        }
        let findings = try await LocationInventorySource().scan(
            for: Identity(bundleID: "org.example.sample", name: "Sample"),
            in: fixture.root
        )
        for domain in domains {
            #expect(findings.completeness.unreadable.contains(fixture.root.url(for: domain).path))
        }
    }
}

private struct ContainerFixture {
    let folder: URL
    let root: FileSystemRoot

    init() throws {
        let temporary = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("brim-container-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        folder = temporary.resolvingSymlinksInPath()
        root = FileSystemRoot(rootURL: folder, userName: "tester")
    }

    func container(_ name: String, xattr: String? = nil, plist: String? = nil) throws -> URL {
        let url = root.url(for: .userContainers).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([1]).write(to: url.appendingPathComponent("state"))
        if let xattr {
            let status = Array(xattr.utf8).withUnsafeBytes {
                setxattr(url.path, "com.apple.containermanager.identifier", $0.baseAddress, $0.count, 0, 0)
            }
            #expect(status == 0)
        }
        if let plist {
            try PropertyListSerialization.data(
                fromPropertyList: ["MCMMetadataIdentifier": plist],
                format: .binary,
                options: 0
            )
            .write(to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    func app(_ name: String, identifier: String) throws -> URL {
        let app = root.url(for: .applications).appendingPathComponent(name + ".app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name],
                                           format: .xml, options: 0).write(to: info)
        return app
    }

    func dictionary(_ name: String, identifier: String, domain: FileSystemRoot.Domain) throws -> URL {
        let dictionary = root.url(for: domain).appendingPathComponent(name + ".dictionary")
        let info = dictionary.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier],
            format: .xml,
            options: 0
        ).write(to: info)
        return dictionary
    }
}
