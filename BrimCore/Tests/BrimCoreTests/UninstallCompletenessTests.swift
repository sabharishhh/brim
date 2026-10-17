@testable import BrimCore
@testable import BrimScan
import XCTest

// swiftformat:disable wrapMultilineStatementBraces
/// What the first real uninstall test found missing when plans were
/// measured against an independent scan.
final class UninstallCompletenessTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    private func receipt(_ packageID: String, token: String, prefix: String) throws {
        let folder = rootURL.appendingPathComponent("private/var/db/receipts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["InstallToken": token, "InstallPrefixPath": prefix, "PackageIdentifier": packageID]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("\(packageID).plist"))
        try Data().write(to: folder.appendingPathComponent("\(packageID).bom"))
    }

    // MARK: - Receipts

    /// Receipts live in `/var/db/receipts`; `/Library/Receipts` is empty on a
    /// modern Mac.
    func testReceiptsAreReadWhereMacOSKeepsThem() async throws {
        try receipt("com.test.app", token: "T1", prefix: "Applications")
        let identity = Identity(bundleID: "com.test.app", name: "Test")
        let found = await InstallerReceiptSource(payload: { _, _ in nil }).scan(for: identity, in: root).evidence
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["com.test.app.bom"])
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// A driver with its own package is tied to the app only by the installer
    /// run both came from.
    func testAPackageFromTheSameInstallerRunComesWithTheApplication() async throws {
        try receipt("com.test.app", token: "T1", prefix: "Applications")
        try receipt("com.vendor.driver", token: "T1", prefix: "Library/Audio/Plug-Ins/HAL")
        try receipt("com.vendor.otherapp", token: "T1", prefix: "Applications")
        try receipt("com.vendor.unrelated", token: "T2", prefix: "Library/Audio/Plug-Ins/HAL")
        let driver = rootURL.appendingPathComponent("Library/Audio/Plug-Ins/HAL/Test.driver")
        try FileManager.default.createDirectory(at: driver, withIntermediateDirectories: true)
        let payloads = ["com.vendor.driver": ["Test.driver"], "com.vendor.otherapp": ["Other.app"],
                        "com.vendor.unrelated": ["Unrelated.driver"]]
        let source = InstallerReceiptSource(payload: { packageID, _ in payloads[packageID] })

        let found = await source.scan(for: Identity(bundleID: "com.test.app", name: "Test"), in: root).evidence
        let names = Set(found.map(\.url.lastPathComponent))

        XCTAssertTrue(names.contains("Test.driver"))
        XCTAssertTrue(names.contains("com.vendor.driver.bom"), "so the driver's receipt is forgotten too")
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "Test.driver" }?.mechanism, "InstallerPayloadSource")
        XCTAssertFalse(names.contains("com.vendor.otherapp.bom"), "another application's package is its own")
        XCTAssertFalse(names.contains("com.vendor.unrelated.bom"), "a different run is a different install")
    }

    /// An updater an installer put in Application Support goes with the app.
    func testAnUpdaterTheInstallerPutOutsideApplicationsComesWithTheApplication() async throws {
        try receipt("com.test.app", token: "T1", prefix: "Applications")
        try receipt("com.vendor.updater", token: "T1", prefix: "Library/Application Support/Vendor/Updater")
        let updater = try bundle("Library/Application Support/Vendor/Updater/Vendor Updater.app", "com.vendor.updater")
        let cache = rootURL.appendingPathComponent("Library/Caches/com.vendor.updater.helper")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let engine = EvidenceEngine(sources: [
            InstallerReceiptSource(payload: { id, _ in id == "com.vendor.updater" ? ["Vendor Updater.app"] : nil }),
            LocationInventorySource()
        ])

        let found = try await engine.discover(identity: Identity(bundleID: "com.test.app", name: "Test"), in: root)
        let byName = Dictionary(
            found.evidence.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(byName[updater.lastPathComponent]?.mechanism, "InstallerPayloadSource")
        XCTAssertNotNil(byName["com.vendor.updater.bom"])
        XCTAssertEqual(byName["com.vendor.updater.helper"]?.humanSentence,
                       "Belongs to Vendor Updater, which was installed with Test.")
        XCTAssertNotEqual(byName["com.vendor.updater.helper"]?.tier, .A)
    }

    /// It stays while another of the developer's packaged apps is installed.
    func testAnUpdaterStaysWhileTheDevelopersOtherPackagedApplicationIsInstalled() async throws {
        try receipt("com.test.app", token: "T1", prefix: "Applications")
        try receipt("com.vendor.updater", token: "T1", prefix: "Library/Application Support/Vendor/Updater")
        try receipt("com.vendor.word", token: "T2", prefix: "Applications")
        _ = try bundle("Library/Application Support/Vendor/Updater/Vendor Updater.app", "com.vendor.updater")
        _ = try bundle("Applications/Word.app", "com.vendor.word")
        let payloads = ["com.vendor.updater": ["Vendor Updater.app"], "com.vendor.word": ["Word.app"]]
        let source = InstallerReceiptSource(payload: { id, _ in payloads[id] })

        let found = await source.scan(for: Identity(bundleID: "com.test.app", name: "Test"), in: root).evidence
        XCTAssertFalse(found.contains { $0.url.lastPathComponent == "Vendor Updater.app" })
        XCTAssertFalse(found.contains { $0.url.lastPathComponent == "com.vendor.updater.bom" })
    }

    /// An app a package put in Library is listed with its receipt; its package
    /// name would never be found by its identifier.
    func testAnApplicationAPackagePutInLibraryIsListedWithItsReceipt() async throws {
        try receipt("com.vendor.package.Updater.app", token: "T9", prefix: "Library/Application Support/Vendor/Updater")
        let updater = try bundle("Library/Application Support/Vendor/Updater/Vendor Updater.app", "com.vendor.updater2")
        _ = try bundle("Library/Application Support/Unpackaged/Loose.app", "com.vendor.loose")

        let listed = await ApplicationInventory(root: root).installedApplications()
        XCTAssertEqual(listed.map(\.url.lastPathComponent), ["Vendor Updater.app"])

        let identity = Identity(bundleID: "com.vendor.updater2", name: "Vendor Updater", bundlePath: updater.path)
        let source = InstallerReceiptSource(payload: { id, _ in
            id == "com.vendor.package.Updater.app" ? ["Vendor Updater.app"] : nil
        })
        let found = await source.scan(for: identity, in: root).evidence
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["com.vendor.package.Updater.app.bom"])
        XCTAssertEqual(found.first?.tier, .A)
    }

    // MARK: - Parts of the application

    func testAPartNamedInsideTheApplicationIsTheApplicationsOwn() {
        let identity = Identity(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
        XCTAssertTrue(identity.ownsIdentifier("com.microsoft.teams2"))
        XCTAssertTrue(identity.ownsIdentifier("com.microsoft.teams2.agent"))
        XCTAssertFalse(identity.ownsIdentifier("com.microsoft.teams2beta"))
        XCTAssertFalse(identity.ownsIdentifier("com.microsoft.vcxpc"))
    }

    /// A component's containers keep their tier inside the app's namespace.
    func testAComponentMatchKeepsItsTierOnlyInsideTheNamespace() {
        let surface = IdentitySurface(bundlePath: "/Applications/Test.app", components: [
            component("/Applications/Test.app", "com.test.app"),
            component("/Applications/Test.app/Contents/PlugIns/W.appex", "com.test.app.widget"),
            component("/Applications/Test.app/Contents/XPCServices/V.xpc", "com.vendor.shared")
        ])
        let identity = Identity(bundleID: "com.test.app", name: "Test", identitySurface: surface)
        let caches = LocationInventory.Location(domain: .userCaches, rule: .bundleIdentifier,
                                                describes: "a cache", sentence: "")
        XCTAssertEqual(caches.matchTier(name: "com.test.app.widget", identity: identity), .B)
        XCTAssertEqual(caches.matchTier(name: "com.vendor.shared", identity: identity), .C)
    }

    /// A library's helper has the same identifier in every app that ships it.
    func testALibrarysHelperIsNotTheApplications() {
        let framework = "/Applications/Test.app/Contents/Frameworks"
        let surface = IdentitySurface(bundlePath: "/Applications/Test.app", components: [
            component("/Applications/Test.app", "com.test.app"),
            component("\(framework)/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc",
                      "org.sparkle-project.DownloaderService"),
            component("\(framework)/Test Framework.framework/Versions/A/Helpers/Test Helper.app",
                      "com.test.app.helper")
        ])
        XCTAssertFalse(surface.searchableBundleIdentifiers.contains("org.sparkle-project.DownloaderService"))
        XCTAssertTrue(surface.searchableBundleIdentifiers.contains("com.test.app.helper"))
    }

    // MARK: - Per-user folders

    /// A per-user folder named with an identifier is proof, whatever folder it
    /// is in.
    func testPerUserFoldersAreMatchedByIdentifierNotByName() {
        XCTAssertEqual(LocationInventory.Location.tier(for: .bundleIdentifier, in: .darwinUserCache), .B)
        XCTAssertEqual(LocationInventory.Location.tier(for: .bundleIdentifier, in: .darwinUserTemp), .B)
    }

    /// Scratch and telemetry folders named inside the identifier.
    func testNamesInsideTheIdentifierInPerUserFoldersAreTheApplications() {
        let rule = LocationInventory.Location.self
        XCTAssertTrue(rule.isTemporary(name: ".com.openai.codex.04BwgK", of: "com.openai.codex"))
        XCTAssertTrue(rule.isTemporary(name: "com.microsoft.teams2.installer_telemetry", of: "com.microsoft.teams2"))
        XCTAssertFalse(rule.isTemporary(name: "com.openai.codexbeta", of: "com.openai.codex"))
        XCTAssertFalse(rule.isTemporary(name: "com.openai.codex.", of: "com.openai.codex"))
    }

    /// WebKit keeps `com.apple.WebKit.GPU+<identifier>` for every app with a web
    /// view.
    func testAServiceFolderKeptForTheApplicationIsTheApplications() {
        let identity = Identity(bundleID: "com.meta.endo", name: "Muse")
        let rule = LocationInventory.Location(domain: .darwinUserCache, rule: .clientOfService,
                                              describes: "", sentence: "")
        XCTAssertEqual(rule.matchTier(name: "com.apple.WebKit.GPU+com.meta.endo", identity: identity), .B)
        XCTAssertNil(rule.matchTier(name: "com.apple.WebKit.GPU+com.meta.endoplus", identity: identity))
        XCTAssertNil(rule.matchTier(name: "com.apple.WebKit.GPU+com.apple.Safari", identity: identity))
        XCTAssertNil(rule.matchTier(name: "+com.meta.endo", identity: identity))
    }

    // MARK: - Provenance

    /// Provenance alone would take `~/.npm` from any app that runs shell
    /// commands, so the name has to tie the item to it as well.
    func testProvenanceCountsOnlyForSomethingNamedForTheApplication() {
        let identity = Identity(bundleID: "com.openai.codex", name: "ChatGPT")
        let names = ProvenanceSource.names(for: identity)
        XCTAssertEqual(Set(names), ["chatgpt", "codex"])
        let ids = ["com.openai.codex"]
        for named in [".codex", "codex-runtimes", "Codex", "codex-alert-codex-notification.wav",
                      ".com.openai.codex.04BwgK"] {
            XCTAssertTrue(ProvenanceSource.isNamed(named, identifiers: ids, names: names), named)
        }
        for other in [".npm", "codexy", "herdr", "my-codex"] {
            XCTAssertFalse(ProvenanceSource.isNamed(other, identifiers: ids, names: names), other)
        }
        XCTAssertEqual(ProvenanceSource.names(for: Identity(bundleID: "com.spotify.client", name: "Spotify")),
                       ["spotify"], "a generic last label names nothing")
    }

    /// A shared provenance value still names one owner when only one bundle is
    /// named for the item.
    func testASharedProvenanceStillNamesOneOwnerWhenOnlyOneIsNamedForTheItem() {
        let stamp = Data([1, 2, 0, 0xA3])
        let owners = ProvenanceSource.owners(of: []) + [
            ProvenanceSource.Owner(stamp: stamp, identifiers: ["com.microsoft.vscode"],
                                   names: ["visual studio code", "code", "vscode"]),
            ProvenanceSource.Owner(stamp: stamp, identifiers: ["com.anthropic.claude-code-url-handler"],
                                   names: ["claude code url handler"])
        ]
        XCTAssertEqual(ProvenanceSource.owner(named: "vscode-cpptools", stamp: stamp, among: owners)?.names.first,
                       "visual studio code")
        let twins = owners + [ProvenanceSource.Owner(stamp: stamp, identifiers: [], names: ["vscode"])]
        XCTAssertNil(ProvenanceSource.owner(named: "vscode-cpptools", stamp: stamp, among: twins),
                     "two bundles with one value, both named for it, cannot be told apart")
        XCTAssertNil(ProvenanceSource.owner(named: "vscode-cpptools", stamp: Data([9]), among: owners))
    }

    /// A leftover is named as Brim recorded its application, not from the
    /// identifier.
    func testALeftoverIsNamedAsBrimRecordedItsApplication() {
        let names = ["com.microsoft.teams2": "Microsoft Teams", "com.microsoft": "Wrong"]
        XCTAssertEqual(LeftoversScanner.recordedName(for: "com.microsoft.teams2", in: names), "Microsoft Teams")
        XCTAssertEqual(LeftoversScanner.recordedName(for: "com.microsoft.teams2.agent", in: names), "Microsoft Teams")
        XCTAssertNil(LeftoversScanner.recordedName(for: "com.microsoft.teams2beta", in: [:]))
        XCTAssertNil(LeftoversScanner.recordedName(for: "com.openai.chat", in: names))
    }

    // MARK: - Another application's files

    /// A prefix rule took `com.google.Chrome.canary.plist` for Chrome.
    func testAMoreSpecificInstalledApplicationKeepsItsOwnFiles() {
        let chrome = Identity(bundleID: "com.google.Chrome", name: "Google Chrome")
        let others = ["com.google.chrome.canary": "Google Chrome Canary"]
        let prefs = URL(fileURLWithPath: "/Users/x/Library/Preferences/com.google.Chrome.canary.plist")
        XCTAssertEqual(TierSVetoEngine.namedFor(prefs, among: others, besides: chrome), "Google Chrome Canary")
        let own = URL(fileURLWithPath: "/Users/x/Library/Preferences/com.google.Chrome.plist")
        XCTAssertNil(TierSVetoEngine.namedFor(own, among: others, besides: chrome))
    }

    // MARK: - The plan

    /// What is inside a removed bundle is not a second row.
    func testWhatIsInsideARemovedBundleIsNotASecondRow() {
        let identity = Identity(bundleID: "com.test.app", name: "Test")
        let bundle = rootURL.appendingPathComponent("Test.app")
        let agent = bundle.appendingPathComponent("Contents/Library/LaunchAgents/com.test.app.agent")
        let plan = plan(identity, [item(bundle, .A, capability: .ok), item(agent, .A, capability: .needsHelper)])
        XCTAssertFalse(plan.steps.contains { $0.target == agent.path })
        XCTAssertFalse(plan.excludedItems.contains { $0.target == agent.path })
        XCTAssertTrue(plan.steps.contains { $0.target == bundle.path && $0.kind == .trashPath })
    }

    /// Removing an authorization plug-in a rule still names can stop the screen
    /// accepting a password, so it stays with that reason.
    func testASignInPlugInStaysWithItsReason() {
        let identity = Identity(bundleID: "com.test.app", name: "Test")
        let plugin = URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins/Test.bundle")
        let plan = plan(identity, [item(plugin, .C, capability: .needsHelper, selection: .unselected)])
        let kept = plan.excludedItems.first { $0.target == plugin.path }
        XCTAssertEqual(kept?.canBeTickedByHand, false)
        XCTAssertTrue(kept?.reason.hasPrefix("Part of how this Mac signs in") ?? false)
        XCTAssertTrue(plan.steps.isEmpty)
    }

    /// Forgetting a receipt with an unmeasured payload cannot show the files are
    /// gone.
    func testAReceiptWithAnUnmeasuredPayloadIsKept() {
        let identity = Identity(bundleID: "com.test.app", name: "Test")
        let bom = URL(fileURLWithPath: "/private/var/db/receipts/com.test.app.bom")
        let receipt = FootprintItem(evidence: Evidence(url: bom, tier: .A, mechanism: "InstallerReceiptSource",
                                                       humanSentence: ""), sizeBytes: 1, capability: .needsHelper)
        let plan = plan(identity, [EvaluatedItem(footprintItem: receipt, selection: .selected, costOfError: .medium)])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.excludedItems.first?.canBeTickedByHand, false)
    }

    /// An app an installer left owned by root is the administrator process's to
    /// move.
    func testTheHelperIsPromisedAnInstalledBundle() {
        XCTAssertTrue(HelperScope.covers("/Applications/Vendor App.app"))
        XCTAssertTrue(HelperScope.covers("/Library/Audio/Plug-Ins/HAL/Vendor.driver"))
        XCTAssertFalse(HelperScope.covers("/Applications/Vendor App"))
        XCTAssertFalse(HelperScope.covers("/Applications/Utilities/Vendor.app"))
        XCTAssertFalse(HelperScope.covers("/Library/Security/SecurityAgentPlugins/Vendor.bundle"))
    }

    // MARK: - Helpers

    private func bundle(_ path: String, _ identifier: String) throws -> URL {
        let url = rootURL.appendingPathComponent(path)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                                                              "CFBundleName": url.deletingPathExtension()
                                                                  .lastPathComponent],
                                           format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    private func component(_ path: String, _ identifier: String) -> IdentitySurface.Component {
        IdentitySurface.Component(path: path, bundleIdentifier: identifier,
                                  name: (path as NSString).lastPathComponent, bundleName: nil,
                                  teamIdentifier: "TEAM", groups: [], urlSchemes: [], exportedTypes: [])
    }

    private func item(
        _ url: URL, _ tier: EvidenceTier, capability: Capability, selection: SelectionState = .selected
    ) -> EvaluatedItem {
        EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: url, tier: tier, mechanism: "Test", humanSentence: ""),
            sizeBytes: 1, capability: capability
        ), selection: selection, costOfError: .medium)
    }

    private func plan(_ identity: Identity, _ items: [EvaluatedItem]) -> Plan {
        Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: items),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity), engineVersion: "test"
        )
    }
}

extension UninstallCompletenessTests {
    /// A library's framework is the library's, as its helpers are: Sparkle's
    /// cache inside another app's folder is not this app's.
    func testALibraryFrameworkIsNotTheApplications() {
        let framework = "/Applications/Test.app/Contents/Frameworks"
        let surface = IdentitySurface(bundlePath: "/Applications/Test.app", components: [
            component("/Applications/Test.app", "com.test.app"),
            component("\(framework)/Sparkle.framework", "org.sparkle-project.Sparkle"),
            component("\(framework)/TestKit.framework", "com.test.kit")
        ])
        XCTAssertFalse(surface.searchableBundleIdentifiers.contains("org.sparkle-project.Sparkle"))
        XCTAssertTrue(surface.searchableBundleIdentifiers.contains("com.test.kit"))
    }
}
