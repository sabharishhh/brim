@testable import BrimCore
import Synchronization
import XCTest

final class TierSVetoEngineTests: XCTestCase {
    func testVetoEngineExcludesSharedFiles() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let root = FileSystemRoot(rootURL: tempRoot)
        let vetoEngine = TierSVetoEngine(root: root)

        let identity = Identity(bundleID: "com.test.app", name: "TestApp")

        let safeURL = tempRoot.appendingPathComponent("SafeFile")
        let sharedURL = tempRoot.appendingPathComponent("OtherApp.app")
        try FileManager.default.createDirectory(at: sharedURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.other.app"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: sharedURL.appendingPathComponent("Contents/Info.plist"))

        let items = [
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: safeURL, tier: .A, mechanism: "Test", humanSentence: "Safe"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low),
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: sharedURL, tier: .A, mechanism: "Test", humanSentence: "Shared"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low)
        ]

        let footprint = EvaluatedFootprint(identity: identity, items: items)
        let vetted = await vetoEngine.applyVeto(to: footprint)

        XCTAssertEqual(vetted.items.count, 2)
        XCTAssertEqual(vetted.items[0].selection, .selected)

        if case let .excluded(reason) = vetted.items[1].selection {
            XCTAssertTrue(reason.contains("claimed by OtherApp"), "Expected exclusion reason to contain claimant name")
        } else {
            XCTFail("Expected shared file to be excluded")
        }
    }

    func testUntickedForeignBundleCannotBePromotedByUninstall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder)
        let target = folder.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.other.app"],
                                           format: .xml, options: 0)
            .write(to: target.appendingPathComponent("Contents/Info.plist"))
        let identity = Identity(bundleID: "org.example.app", name: "Example")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: target, tier: .C, mechanism: "test", humanSentence: "Name match"),
            sizeBytes: 1, capability: .ok
        ), selection: .unselected, costOfError: .medium)
        let vetted = await TierSVetoEngine(root: root).applyVeto(
            to: EvaluatedFootprint(identity: identity, items: [item])
        )
        guard case .excluded = vetted.items[0].selection else { return XCTFail("Shared row remained tickable") }
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity).tickingByHand([target.path])
        let plan = Planner().createPlan(from: vetted, intent: intent, engineVersion: "test")
        XCTAssertFalse(plan.steps.contains { $0.target == target.path })
        XCTAssertEqual(plan.excludedItems.first?.canBeTickedByHand, false)
    }

    func testNestedAppClaimAndIncompleteOwnershipVetoUntickedGroups() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let other = root.url(for: .applications).appendingPathComponent("Vendor/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: target, tier: .A, mechanism: "test", humanSentence: "Declared group"),
            sizeBytes: 1, capability: .ok
        ), selection: .unselected, costOfError: .medium)
        let footprint = EvaluatedFootprint(identity: Identity(name: "Example"), items: [item])
        let claimed = TierSVetoEngine(root: root) { bundle, _ in
            (bundle.lastPathComponent == "Other.app" ? ["group.org.example.shared"] : [], true)
        }
        let result = await claimed.applyVeto(to: footprint)
        XCTAssertEqual(result.items[0].selection, .excluded(reason: "Shared with Other."))

        let incomplete = TierSVetoEngine(root: root) { _, _ in ([], false) }
        let unavailable = await incomplete.applyVeto(to: footprint)
        XCTAssertEqual(unavailable.items[0].selection,
                       .excluded(reason: "Shared ownership could not be checked."))
    }
}

final class TierSClaimReadTests: XCTestCase {
    func testRawGroupClaimsAreReadOnceAndRefreshedForEachVeto() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let selected = try makeBundle(at: root.url(for: .applications).appendingPathComponent("Editor.app"),
                                      identifier: "org.example.editor")
        let registered = try makeBundle(at: folder.appendingPathComponent("Tools/Worker.app"),
                                        identifier: "org.example.worker")
        let unknown = root.url(for: .applications).appendingPathComponent("Unknown.app")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let component = Self.claimedComponent(
            at: selected.appendingPathComponent("Contents/Helpers/Worker.app"),
            identifier: "org.example.worker", groups: []
        )
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path,
                                identitySurface: IdentitySurface(bundlePath: selected.path, components: [component]))
        let reads = ClaimCounter()
        let lookups = ClaimCounter()
        let engine = rawClaimsEngine(root: root, registered: registered, reads: reads, lookups: lookups)
        let items = ["group.org.example.registered", "group.org.example.unknown"].map {
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent($0))
        }
        let footprint = EvaluatedFootprint(identity: identity, items: items)

        // The group pass previously reopened every bundle after the identity pass.
        // Raw claims must survive even when the host has no usable identifier.
        let first = await engine.applyVeto(to: footprint)
        XCTAssertEqual(first.items.map(\.selection), [.excluded(reason: "Shared with Worker."),
                                                      .excluded(reason: "Shared with Unknown.")])
        XCTAssertTrue(first.completeness.unreadable.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }.contains(unknown.resolvingSymlinksInPath().path))
        XCTAssertEqual(reads.value.withLock { $0 }, [registered.resolvingSymlinksInPath().path: 1,
                                                     unknown.resolvingSymlinksInPath().path: 1])
        XCTAssertEqual(lookups.value.withLock { $0 }, ["org.example.editor": 1, "org.example.worker": 1])
        XCTAssertTrue(first.protectedComponentIdentifiers.contains("org.example.worker"))

        let second = await engine.applyVeto(to: footprint)
        let unchecked: SelectionState = .excluded(reason: "Shared ownership could not be checked.")
        XCTAssertEqual(second.items.map(\.selection), Array(repeating: unchecked, count: 2))
        XCTAssertEqual(reads.value.withLock { $0 }, [registered.resolvingSymlinksInPath().path: 2,
                                                     unknown.resolvingSymlinksInPath().path: 2])
    }

    func testSelectedBundleAndItsRegisteredPartsNeverClaimTheirOwnGroups() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let selected = try makeBundle(at: root.url(for: .applications).appendingPathComponent("Editor.app"),
                                      identifier: "org.example.editor")
        let helper = try makeBundle(at: selected.appendingPathComponent("Contents/Helpers/Worker.app"),
                                    identifier: "org.example.worker")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path,
                                identitySurface: IdentitySurface(bundlePath: selected.path, components: [
                                    Self.claimedComponent(at: helper, identifier: "org.example.worker", groups: [])
                                ]))
        let reads = Mutex(0)
        let engine = TierSVetoEngine(root: root, lookup: { _ in [selected, helper] }, readClaims: { bundle, _ in
            reads.withLock { $0 += 1 }
            return (IdentitySurface(bundlePath: bundle.path, components: [
                Self.claimedComponent(at: bundle, identifier: "org.example.worker",
                                      groups: ["group.org.example.own"])
            ]), true)
        })
        let result = await engine.applyVeto(to: EvaluatedFootprint(identity: identity, items: [
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.own"))
        ]))
        XCTAssertEqual(result.items.first?.selection, .selected)
        XCTAssertTrue(result.completeness.isComplete)
        XCTAssertEqual(reads.withLock { $0 }, 0)
    }

    func testIncompleteRawClaimsProtectKnownGroupsAndVetoUncheckedGroups() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let other = try makeBundle(at: root.url(for: .applications).appendingPathComponent("Worker.app"),
                                   identifier: "org.example.worker")
        let engine = TierSVetoEngine(root: root, readClaims: { bundle, _ in
            (IdentitySurface(bundlePath: bundle.path, components: [
                Self.claimedComponent(at: bundle, identifier: "org.example.worker",
                                      groups: ["group.org.example.shared"])
            ]), false)
        })
        let result = await engine.applyVeto(to: EvaluatedFootprint(identity: Identity(name: "Editor"), items: [
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared")),
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.unchecked")),
            groupItem(folder.appendingPathComponent("Support"))
        ]))
        XCTAssertEqual(result.items.map(\.selection), [.excluded(reason: "Shared with Worker."),
                                                       .excluded(reason: "Shared ownership could not be checked."),
                                                       .unselected])
        XCTAssertTrue(result.completeness.unreadable.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }.contains(other.resolvingSymlinksInPath().path))
    }

    func testCancelledVetoStopsBeforeReadingBundleClaimsAndReportsIncompleteCoverage() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        _ = try makeBundle(at: root.url(for: .applications).appendingPathComponent("Worker.app"),
                           identifier: "org.example.worker")
        let reads = Mutex(0)
        let engine = TierSVetoEngine(root: root, readClaims: { bundle, _ in
            reads.withLock { $0 += 1 }
            return (IdentitySurface(bundlePath: bundle.path, components: []), true)
        })
        let item = groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared"))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.applyVeto(to: EvaluatedFootprint(identity: Identity(name: "Editor"), items: [item]))
        }.value
        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertFalse(result.completeness.isComplete)
        XCTAssertFalse(result.completeness.timedOut.isEmpty)
        XCTAssertEqual(result.items.first?.selection, .excluded(reason: "Shared ownership could not be checked."))
    }

    func testCancellationAtLastBundleReadKeepsClaimsAndReportsIncompleteCoverage() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        _ = try makeBundle(at: root.url(for: .applications).appendingPathComponent("Worker.app"),
                           identifier: "org.example.worker")
        let engine = TierSVetoEngine(root: root, readClaims: { bundle, _ in
            // Cancellation after the last read had no next bundle checkpoint.
            withUnsafeCurrentTask { $0?.cancel() }
            return (IdentitySurface(bundlePath: bundle.path, components: [
                Self.claimedComponent(at: bundle, identifier: "org.example.worker",
                                      groups: ["group.org.example.shared"])
            ]), true)
        })
        let result = await engine.applyVeto(to: EvaluatedFootprint(identity: Identity(name: "Editor"), items: [
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared")),
            groupItem(root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.unchecked")),
            groupItem(folder.appendingPathComponent("Support"))
        ]))
        XCTAssertEqual(result.items.map(\.selection), [.excluded(reason: "Shared with Worker."),
                                                       .excluded(reason: "Shared ownership could not be checked."),
                                                       .unselected])
        XCTAssertEqual(result.completeness.timedOut, [root.rootURL.path])
        XCTAssertFalse(result.completeness.isComplete)
    }

    private func makeBundle(at app: URL, identifier: String) throws -> URL {
        let metadata = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: metadata)
        return app
    }

    private func rawClaimsEngine(
        root: FileSystemRoot, registered: URL,
        reads: ClaimCounter, lookups: ClaimCounter
    ) -> TierSVetoEngine {
        TierSVetoEngine(root: root, lookup: { identifier in
            lookups.value.withLock { $0[identifier, default: 0] += 1 }
            return identifier == "org.example.worker" ? [registered] : []
        }, readClaims: { bundle, _ in
            let path = bundle.resolvingSymlinksInPath().path
            let count = reads.value.withLock { counts in
                counts[path, default: 0] += 1
                return counts[path, default: 0]
            }
            let isRegistered = path == registered.resolvingSymlinksInPath().path
            let group = isRegistered ? "group.org.example.registered" : "group.org.example.unknown"
            // A second veto must use new reads rather than a persistent cache.
            let groups = count == 1 ? [group] : []
            let identifier = isRegistered ? "org.example.worker" : nil
            return (IdentitySurface(bundlePath: bundle.path, components: [
                Self.claimedComponent(at: bundle, identifier: identifier, groups: groups)
            ]), true)
        })
    }

    private static func claimedComponent(
        at bundle: URL, identifier: String?, groups: [String]
    ) -> IdentitySurface.Component {
        IdentitySurface.Component(path: bundle.path, bundleIdentifier: identifier,
                                  name: bundle.deletingPathExtension().lastPathComponent, bundleName: nil,
                                  teamIdentifier: nil, groups: groups, urlSchemes: [], exportedTypes: [])
    }

    private func groupItem(_ url: URL) -> EvaluatedItem {
        EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: url, tier: .A, mechanism: "fixture", humanSentence: "Declared group"),
            sizeBytes: 0, capability: .ok
        ), selection: .selected, costOfError: .medium)
    }
}

private final class ClaimCounter: Sendable {
    let value = Mutex<[String: Int]>([:])
}
