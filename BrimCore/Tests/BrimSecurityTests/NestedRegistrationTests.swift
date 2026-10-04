import BrimCore
import BrimOps
import BrimScan
import Testing
import XCTest

/// After Muse was removed, Launch Services still listed Sparkle's
/// `Updater.app` inside `Muse.app` and two copies Sparkle kept in its cache
/// folder, all pointing at nothing. Unregistering the application does not
/// reach the applications inside it, so they are found before it goes.
final class NestedRegistrationTests: XCTestCase {
    func testApplicationsInsideSomethingRemovedAreFound() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nested-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let host = folder.appendingPathComponent("Host.app")
        let updater = host.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app")
        let cached = folder.appendingPathComponent("Caches/Launcher/abc/Updater.app")
        for url in [updater, cached] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: host.path), [updater.path])
        let caches = folder.appendingPathComponent("Caches")
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: caches.path), [cached.path])
        let absent = folder.appendingPathComponent("none")
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: absent.path), [])
    }

    /// Teams' embedded browser had already moved to a newer version folder,
    /// and three helpers in the old one stayed registered through the
    /// uninstall: nothing on disk named them any more.
    func testRecordsInsideARemovedPathThatPointAtNothingAreFound() async throws {
        let dump = """
        path:                       /Applications/Gone.app/Contents/Helpers/Helper (GPU).app (0x653c)
        path:                       /Applications/Gone.app (0x6864)
        path:                       /Applications/GoneToo.app (0x6865)
        path:                       /System/Applications/Notes.app (0x1)
        name:                       Something else
        """
        let records = try await LaunchServicesRegistration.staleRecords(inside: ["/Applications/Gone.app"], dump: dump)
        XCTAssertEqual(
            records,
            ["/Applications/Gone.app/Contents/Helpers/Helper (GPU).app"]
        )
    }
}

struct ScopedNestedRegistrationTests {
    @Test func selectedSupportFoldersIncludeTheirAppsAndKeepOtherCopies() throws {
        let fixture = try ScopedRegistrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let host = try fixture.app("Applications/Example.app", id: "org.example.host")
        let support = fixture.folder.appendingPathComponent("Support")
        let helper = try fixture.app("Support/Helper.APP", id: "org.example.helper")
        let survivor = try fixture.app("Other/Helper.app", id: "org.example.helper")
        let kept = try fixture.app("Kept/Kept.app", id: "org.example.kept")
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Other.app"),
                                                   withDestinationURL: survivor)
        let identity = Identity(bundleID: "org.example.host", name: "Example", bundlePath: host.path)
        let check = CapabilitySearchScanner.launchServicesCheck(
            identity: identity, in: fixture.realRoot, removalLocations: [host.path, support.path],
            discoverApplications: true,
            lookup: { identifier in
                identifier == "org.example.host" ? [host] : [helper, survivor, kept]
            }
        )
        #expect(check.coverage.available)
        #expect(Set(check.registrations.compactMap(\.programPath)) == [host.path, helper.path])
        let items = [fixture.item(host), fixture.item(support), fixture.item(kept, selection: .unselected)]
        let plan = Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: items),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity), engineVersion: "test",
            capabilityReport: .init(checks: [check], signatureCoverage: [])
        )
        let unregister = plan.steps.filter { $0.kind == .unregisterLaunchServices }
        #expect(Set(unregister.map(\.target)) == [host.path, helper.path])
        #expect(unregister.first { $0.target == helper.path }?.registrationBundleID == "org.example.helper")
    }

    @Test func explicitRemnantCleanupPlansAndRechecksExactExternalApps() throws {
        let fixture = try ScopedRegistrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let support = fixture.folder.appendingPathComponent("Support")
        let helper = try fixture.app("Support/Helper.app", id: "org.example.helper")
        let survivor = try fixture.app("Other/Helper.app", id: "org.example.helper")
        let identity = Identity(name: "Leftovers")
        let before = CapabilitySearchScanner.launchServicesCheck(
            identity: identity, in: fixture.realRoot, removalLocations: [support.path], discoverApplications: true,
            lookup: { _ in [helper, survivor] }
        )
        let plan = Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: [fixture.item(support)]),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity, specificTargets: [support]),
            engineVersion: "test", capabilityReport: .init(checks: [before], signatureCoverage: [])
        )
        #expect(plan.steps.filter { $0.kind == .unregisterLaunchServices }.map(\.target) == [helper.path])
        let retained = CapabilitySearchScanner.launchServicesCheck(
            identity: identity, in: fixture.realRoot, expectedRegistrations: before.registrations,
            lookup: { _ in [helper, survivor] }
        )
        #expect(retained.registrations.map(\.programPath) == [helper.path])
        let gone = CapabilitySearchScanner.launchServicesCheck(
            identity: identity, in: fixture.realRoot, expectedRegistrations: before.registrations,
            lookup: { _ in [survivor] }
        )
        #expect(gone.coverage.available)
        #expect(gone.registrations.isEmpty)
        #expect(!plan.steps.contains { $0.kind == .resetPrivacyGrants })
    }

    @Test func unreadableDiscoveryAndDirectoryAliasesNeverCertifyAbsence() throws {
        let fixture = try ScopedRegistrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let app = try fixture.app("Other/Helper.app", id: "org.example.helper")
        let alias = fixture.folder.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app.deletingLastPathComponent())
        let check = CapabilitySearchScanner.launchServicesCheck(
            identity: Identity(name: "Leftovers"), in: fixture.realRoot,
            removalLocations: [alias.appendingPathComponent("Helper.app").path], discoverApplications: true,
            lookup: { _ in Issue.record("A directory alias must not discover outside apps"); return [app] }
        )
        #expect(!check.coverage.available)
        #expect(check.registrations.isEmpty)
        let later = CapabilitySearchScanner.launchServicesCheck(
            identity: Identity(name: "Leftovers"), in: fixture.realRoot,
            reviewedCoverage: check.coverage, lookup: { _ in [] }
        )
        #expect(!later.coverage.available)
        let synthetic = CapabilitySearchScanner.launchServicesCheck(
            identity: Identity(bundleID: "org.example.helper", name: "Helper"),
            in: FileSystemRoot(rootURL: fixture.folder, userName: "tester"),
            lookup: { _ in Issue.record("A fixture must not query Launch Services"); return [app] }
        )
        #expect(synthetic.coverage.absence == .byDesign)
    }

    @Test func metadataLinksAndOversizedMetadataCannotNameAnApplication() throws {
        let fixture = try ScopedRegistrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let app = try fixture.app("Helper.app", id: "org.example.helper")
        let metadata = app.appendingPathComponent("Contents/Info.plist")
        #expect(CapabilitySearchScanner.applicationIdentifier(at: app.path) == "org.example.helper")
        let elsewhere = fixture.folder.appendingPathComponent("Elsewhere.plist")
        try FileManager.default.moveItem(at: metadata, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: elsewhere)
        #expect(CapabilitySearchScanner.applicationIdentifier(at: app.path) == nil)
        try FileManager.default.removeItem(at: metadata)
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: metadata)
        #expect(CapabilitySearchScanner.applicationIdentifier(at: app.path) == nil)
    }
}

private struct ScopedRegistrationFixture {
    let folder: URL
    let realRoot = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"), userName: "tester")

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scoped-registrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func app(_ path: String, id: String) throws -> URL {
        let app = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                          format: .xml, options: 0)
        try metadata.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func item(_ url: URL, selection: SelectionState = .selected) -> EvaluatedItem {
        EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: url, tier: .B, mechanism: "test", humanSentence: "Reviewed application location."),
            sizeBytes: 1, capability: .ok
        ), selection: selection, costOfError: .medium)
    }
}
