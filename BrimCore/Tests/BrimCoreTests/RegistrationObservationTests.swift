import BrimCore
@testable import BrimScan
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces
struct RegistrationObservationTests {
    private func record(_ uuid: String, path: String?, parent: String? = nil,
                        namespace: String = "account", identifier: String = "2.com.example.app") -> BTMRecord {
        BTMRecord(uuid: uuid, name: nil, developerName: nil, type: "app", disposition: "off",
                  identifier: identifier, rawURLPath: path, parentIdentifier: parent,
                  bundleIdentifier: "com.example.app", namespace: namespace)
    }

    @Test func ambiguousParentsDoNotInventMissingHelpers() async {
        // Two copies formerly resolved a relative helper against whichever
        // parent happened to be inserted last, and falsely called it gone.
        let records = [record("a", path: "/Applications/First.app"),
                       record("b", path: "/Applications/Second.app"),
                       record("child", path: "Contents/Helper.app", parent: "2.com.example.app",
                              identifier: "4.com.example.helper")]
        let snapshot = await BackgroundItemSurface(read: { records }).snapshot(in: FileSystemRoot())
        let child = snapshot.registrations.first { $0.recordIdentity == "child" }
        #expect(child?.targetPresence.isUnknown == true)
        #expect(child?.isStale == false)
        #expect(child?.owningBundleID == nil)
    }

    @Test func accountNamespacesKeepDuplicateIDsDistinct() async {
        let records = [record("same", path: nil, namespace: "first"),
                       record("same", path: nil, namespace: "second")]
        let snapshot = await BackgroundItemSurface(read: { records }).snapshot(in: FileSystemRoot())
        #expect(Set(snapshot.registrations.map(\.id)).count == 2)
        #expect(snapshot.registrations.allSatisfy { !$0.isStale })
    }

    @Test func cyclicParentsRemainUnknown() async {
        let records = [record("a", path: "Helper.app", parent: "b", identifier: "a"),
                       record("b", path: "Helper.app", parent: "a", identifier: "b")]
        let snapshot = await BackgroundItemSurface(read: { records }).snapshot(in: FileSystemRoot())
        #expect(snapshot.registrations.allSatisfy { $0.targetPresence.isUnknown && !$0.isStale })
        #expect(snapshot.registrations.allSatisfy { $0.owningBundleID == nil })
    }

    @Test func cloudProviderDataCannotBePromotedIntoRemoval() async throws {
        // Provider containers may hold unsynced files. An identifier match
        // formerly selected them with the application's regenerable data.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory)
        let bundle = directory.appendingPathComponent("Applications/Cloud.app")
        let surface = CapabilitySurface(declarations: [
            .init(.fileProvider, key: "NSExtensionPointIdentifier", value: "com.apple.fileprovider-nonui",
                  path: bundle.appendingPathComponent("Contents/PlugIns/Files.appex").path)
        ])
        let identity = Identity(bundleID: "com.example.cloud", name: "Cloud", bundlePath: bundle.path,
                                capabilitySurface: surface)
        let protectedPaths = ["Containers/com.example.cloud", "Group Containers/group.example.cloud",
                              "CloudStorage/Cloud", "Application Support/Cloud", "Mobile Documents/Cloud"]
        let paths = protectedPaths.map { directory.appendingPathComponent("Users/test/Library/" + $0) } + [bundle]
        let items = paths.map { url in
            FootprintItem(evidence: Evidence(url: url, tier: .B, mechanism: "identifier", humanSentence: "Owned"),
                          sizeBytes: 1, capability: .ok)
        }
        let checker = SafetyChecker(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"))
        let engine = SafetyEngine(safetyChecker: checker, vetoEngine: TierSVetoEngine(root: root))
        let evaluated = await engine.evaluate(footprint: Footprint(identity: identity, items: items))
        for item in evaluated.items.dropLast() {
            guard case .excluded = item.selection else {
                Issue.record("Provider data must remain excluded, including hand-selected rows")
                continue
            }
            #expect(item.costOfError == .high)
        }
        #expect(evaluated.items.last?.selection == .selected)
        let handSelected = paths.map(\.path)
        let plan = Planner().createPlan(from: evaluated, intent: PlanIntent(
            type: .uninstall, subjectIdentity: identity, tickedByHand: handSelected
        ), engineVersion: "test")
        #expect(!plan.steps.contains { step in protectedPaths.contains { step.target.contains($0) } })
    }

    @Test func disconnectedVolumeIsNotDeletedContent() {
        #expect(PathObservation.observe("/Volumes/brim-unmounted-\(UUID())/App.app").isUnknown)
        #expect(PathObservation.observe(nil).isUnknown)
        #expect(PathObservation.observe("relative/Helper.app").isUnknown)
    }

    @Test func missingLaunchdLabelAndRelativeProgramAreNotInvented() {
        #expect(LaunchdJobDefinition(dictionary: ["Program": "/bin/sleep"]) == nil)
        let definition = LaunchdJobDefinition(dictionary: ["Label": "com.example.job",
                                                           "ProgramArguments": ["brim-missing-\(UUID())"]])
        #expect(definition?.resolvedProgram(plistPath: "/Library/LaunchAgents/job.plist") == nil)
        let escaped = LaunchdJobDefinition(dictionary: ["Label": "com.example.job",
                                                        "BundleProgram": "../../bin/sleep"])
        #expect(escaped?
            .resolvedProgram(plistPath: "/Applications/A.app/Contents/Library/LaunchAgents/job.plist") == nil)
    }

    @Test func pathScopedExtensionDoesNotClaimAnotherCopy() {
        let registration = Registration(kind: .appExtension, identifier: "com.example.app.helper",
                                        label: "Helper", owningBundleID: "com.example.app",
                                        programPath: "/Applications/First.app/Contents/Helper.appex",
                                        targetExists: true, evidence: "")
        #expect(registration.belongs(to: Identity(bundleID: "com.example.app", name: "First"),
                                     bundleURL: URL(fileURLWithPath: "/Applications/First.app")))
        #expect(!registration.belongs(to: Identity(bundleID: "com.example.app", name: "Second"),
                                      bundleURL: URL(fileURLWithPath: "/Applications/Second.app")))
    }

    @Test func legacyRecordDoesNotAcquireAPathObservation() throws {
        let registration = Registration(kind: .backgroundItem, identifier: "com.example.app",
                                        label: "App", targetExists: false, evidence: "")
        let encoded = try JSONEncoder().encode(registration)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "observedTarget")
        let old = try JSONDecoder().decode(Registration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.targetPresence.isUnknown)
        #expect(!old.isStale)
    }

    @Test func explicitRelativeProgramDoesNotUseArgumentSearchRules() {
        let invalid = LaunchdJobDefinition(dictionary: ["Label": "org.example.job", "Program": "sleep"])
        #expect(invalid?.resolvedProgram(plistPath: "/Library/LaunchAgents/job.plist") == nil)
        let searched = LaunchdJobDefinition(dictionary: ["Label": "org.example.job", "ProgramArguments": ["sleep"]])
        #expect(searched?.resolvedProgram(plistPath: "/Library/LaunchAgents/job.plist") != nil)
    }

    @Test func successfulToolExitWithoutAListingDoesNotProveAbsence() async {
        // PluginKit can return status zero with "match: Connection invalid".
        let plugins = await AppExtensionSurface(read: { "match: Connection invalid" }).snapshot(in: FileSystemRoot())
        let system = await SystemExtensionSurface(read: { "Connection failed" }).snapshot(in: FileSystemRoot())
        let firewall = await FirewallSurface(read: { "Permission denied" }).snapshot(in: FileSystemRoot())
        #expect(!plugins.coverage.available)
        #expect(!system.coverage.available)
        #expect(!firewall.coverage.available)
        #expect(plugins.registrations.isEmpty)
    }

    @Test func partialExtensionListingRetainsUsefulRecordsAndItsGap() async {
        let output = "     org.example.widget(1)\tUUID\t2026-10-02\t"
            + "/Applications/Editor.app/Contents/Widget.appex\n (2 plug-ins)"
        let snapshot = await AppExtensionSurface(read: { output }).snapshot(in: FileSystemRoot())
        #expect(snapshot.registrations.count == 1)
        #expect(snapshot.registrations.first?.recordIdentity == "UUID")
        #expect(!snapshot.coverage.available)
        #expect(snapshot.registrations.first?.isClearedByMacOS == false)
    }

    @Test func emptyMeasuredListsAreDifferentFromFailedReads() async {
        let plugins = await AppExtensionSurface(read: { " (0 plug-ins)" }).snapshot(in: FileSystemRoot())
        let system = await SystemExtensionSurface(read: { "0 extension(s)" }).snapshot(in: FileSystemRoot())
        let firewall = await FirewallSurface(read: { "Total number of apps = 0" }).snapshot(in: FileSystemRoot())
        #expect(plugins.coverage.available && system.coverage.available && firewall.coverage.available)
    }

    @Test func receiptPayloadRejectsTraversalAndRetainsNestedFiles() {
        let root = FileSystemRoot(
            rootURL: URL(fileURLWithPath: "/private/tmp/brim-receipt-fixture"),
            userName: "tester"
        )
        #expect(InstallerReceiptSource
            .payloadPaths(listing: "../Other.app/file", prefix: "Applications", in: root) == nil)
        #expect(InstallerReceiptSource.payloadPaths(listing: "/etc/file", prefix: "Applications", in: root) == nil)
        #expect(InstallerReceiptSource.payloadPaths(listing: "", prefix: "Applications", in: root) == nil)
        #expect(InstallerReceiptSource.payloadPaths(
            listing: "Editor.app/Contents/Info.plist",
            prefix: "Applications",
            in: root
        ) == ["/private/tmp/brim-receipt-fixture/Applications/Editor.app/Contents/Info.plist"])
    }

    @Test func revalidationIgnoresTimeButRetainsCoverageAndReaderVersion() {
        func report(time: Date, version: Int = 2,
                    coverage: RegistrationCoverage = .available(.backgroundItem)) -> CapabilitySearchReport {
            CapabilitySearchReport(checks: [.init(capability: .backgroundItem, declaration: .unknown,
                                                  coverage: coverage, observedAt: time, readerVersion: version)],
                                   signatureCoverage: [])
        }
        let reviewed = report(time: Date(timeIntervalSince1970: 1))
        #expect(reviewed.reviewScope == report(time: Date(timeIntervalSince1970: 5)).reviewScope)
        #expect(reviewed.reviewScope != report(time: Date(), version: 3).reviewScope)
        #expect(reviewed.reviewScope != report(time: Date(), coverage: .unavailable(.backgroundItem, "Denied"))
            .reviewScope)
    }

    @Test func exactCandidateLookupFindsCustomCopiesAndDeduplicatesAliases() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Custom/Editor.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.example.editor"],
            format: .xml,
            options: 0
        )
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let alias = folder.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let inventory = InstalledBundleInventory.read(
            in: root,
            including: ["org.example.editor"],
            lookup: { _ in [app, alias] }
        )
        #expect(inventory.bundles.count == 1)
        #expect(inventory.completeness.isComplete)
        let wrong = InstalledBundleInventory.read(in: root, including: ["org.other.app"], lookup: { _ in [app] })
        #expect(wrong.bundles.isEmpty)
    }

    @Test func aLinkToAnOfflineVolumeDoesNotBecomeAStaleTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let alias = folder.appendingPathComponent("Offline.app")
        try FileManager.default.createSymbolicLink(atPath: alias.path,
                                                   withDestinationPath: "/Volumes/brim-unmounted-\(UUID())/Editor.app")
        #expect(PathObservation.observe(alias.path).isPresent)
        #expect(PathObservation.observe(alias.path, followingLinks: true).isUnknown)
    }

    @Test func privacyResetExcludesSharedAndLibraryComponentIdentifiers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Editor.app")
        let hostID = "org.example.editor"
        let paths = [app, app.appendingPathComponent("Contents/XPCServices/Worker.xpc"),
                     app
                         .appendingPathComponent(
                             "Contents/Frameworks/Library.framework/Versions/A/XPCServices/Agent.xpc"
                         )]
        let ids = [hostID, "org.example.shared.worker", "net.library.agent"]
        for path in paths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let components = zip(paths, ids).map { path, id in
            IdentitySurface.Component(path: path.path, bundleIdentifier: id, name: id, bundleName: nil,
                                      teamIdentifier: "EXAMPLE", groups: [], urlSchemes: [], exportedTypes: [])
        }
        let identity = Identity(bundleID: hostID, name: "Editor", bundlePath: app.path)
            .attaching(
                IdentitySurface(bundlePath: app.path, components: components),
                capabilities: CapabilitySurface(declarations: [])
            )
        let selected = EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(
            url: app,
            tier: .A,
            mechanism: "AppBundleSource",
            humanSentence: "Fixture"
        ), sizeBytes: 0, capability: .ok),
        selection: .selected, costOfError: .medium)
        let evaluated = EvaluatedFootprint(
            identity: identity,
            items: [selected],
            protectedComponentIdentifiers: [ids[1]]
        )
        let plan = Planner().createPlan(
            from: evaluated,
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
            engineVersion: "test"
        )
        #expect(plan.steps.filter { $0.kind == .resetPrivacyGrants }.map(\.target) == [hostID])
        #expect(plan.intent.subjectIdentity.identitySurface == identity.identitySurface)
    }
}
