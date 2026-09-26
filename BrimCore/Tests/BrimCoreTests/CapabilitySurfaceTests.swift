@testable import BrimCore
@testable import BrimScan
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
import XCTest

final class CapabilitySurfaceTests: XCTestCase {
    private var root: FileSystemRoot!
    private var app: URL!

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-capabilities-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: folder, userName: "tester")
        app = root.url(for: .applications).appendingPathComponent("Editor.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root.rootURL)
    }

    private func info(_ values: [String: Any], at bundle: URL) throws {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values,
                                                      format: .xml, options: 0)
        try data.write(to: url)
    }

    private func read(_ signature: @escaping (URL) -> BundleSurfaceReader.Signature)
        -> (IdentitySurface, CapabilitySurface) {
        BundleSurfaceReader.read(at: app, in: root, budget: .unlimited, signature: signature)
    }

    func testEmbeddedIdentifiersAndDeclarationsRouteSearchWithoutElevatingNames() async throws {
        try info([
            "CFBundleIdentifier": "org.example.editor",
            "CFBundleName": "Edit",
            "CFBundleDisplayName": "Editor Pro",
            "CFBundleExecutable": "EditorCore",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["editdoc"]]],
            "UTExportedTypeDeclarations": [["UTTypeIdentifier": "org.example.document"]],
            "SMPrivilegedExecutables": ["org.example.privileged": "identifier \"org.example.privileged\""],
            "NEProviderClasses": ["Packet": "Provider"],
            "NSCameraUsageDescription": "Camera access"
        ], at: app)
        let service = app.appendingPathComponent("Contents/XPCServices/Worker.xpc")
        try info(["CFBundleIdentifier": "org.other.worker", "CFBundleName": "WorkerData"], at: service)
        let group = root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let workerState = root.url(for: .userLibrary)
            .appendingPathComponent("Caches/org.other.worker")
        try FileManager.default.createDirectory(at: workerState, withIntermediateDirectories: true)

        let (surface, capabilities) = read { url in
            BundleSurfaceReader.Signature(
                identifier: url == self.app ? "org.example.signed" : "org.other.worker",
                team: "EXAMPLETEAM",
                entitlements: ["com.apple.security.application-groups": ["group.org.example.shared"],
                               "com.apple.security.device.camera": true]
            )
        }
        XCTAssertTrue(surface.bundleIdentifiers.contains("org.other.worker"))
        XCTAssertTrue(surface.bundleIdentifiers.contains("org.example.signed"))
        XCTAssertTrue(surface.names.contains("Editor Pro"))
        XCTAssertTrue(surface.names.contains("WorkerData"))
        XCTAssertTrue(surface.urlSchemes.contains("editdoc"))
        XCTAssertTrue(surface.exportedTypes.contains("org.example.document"))
        XCTAssertEqual(capabilities.state(for: .vpnConfiguration), .declared)
        XCTAssertEqual(capabilities.state(for: .launchServices), .declared)
        XCTAssertEqual(capabilities.state(for: .privacyGrant), .declared)
        XCTAssertEqual(capabilities.state(for: .applicationGroups), .declared)
        XCTAssertEqual(surface.helperRequirements.keys.sorted(), ["org.example.privileged"])

        let identity = Identity(bundleID: "org.example.editor", name: "Editor")
            .attaching(surface, capabilities: capabilities)
        let state = try await BundleIdentifierStateSource().evidence(for: identity, in: root)
        XCTAssertEqual(state.first { $0.url.path == workerState.path }?.tier, .C)
        let groups = try await GroupContainerSource().evidence(for: identity, in: root)
        XCTAssertEqual(groups.first { $0.url.path == group.path }?.tier, .A)
        let match = root.url(for: .userApplicationSupport).appendingPathComponent("WorkerData")
        try FileManager.default.createDirectory(at: match, withIntermediateDirectories: true)
        let names = try await BundleIdentifierComponentSource().evidence(for: identity, in: root)
        XCTAssertEqual(names.first { $0.url.path == match.path }?.tier, .C)
    }

    func testUnsignedCodeUsesInfoOnlyAndLeavesEntitlementAbsenceUnknown() throws {
        try info(["CFBundleIdentifier": "org.example.editor",
                  "NSCameraUsageDescription": "Camera access",
                  "CFBundleURLTypes": [["CFBundleURLSchemes": ["editdoc"]]]], at: app)
        let (_, capabilities) = read { _ in
            BundleSurfaceReader.Signature(entitlements: [
                "com.apple.security.application-groups": ["group.org.example.shared"],
                "com.apple.developer.networking.networkextension": true
            ], gap: "Unsigned code.")
        }
        XCTAssertEqual(capabilities.state(for: .privacyGrant), .declared)
        XCTAssertEqual(capabilities.state(for: .launchServices), .declared)
        XCTAssertEqual(capabilities.state(for: .applicationGroups), .unknown)
        XCTAssertEqual(capabilities.state(for: .vpnConfiguration), .unknown)
        XCTAssertFalse(capabilities.declarations.contains { $0.capability == .applicationGroups })
        XCTAssertEqual(capabilities.signatureGaps.count, 1)
    }

    func testEscapingBundleLinkIsReportedAsUnreadable() throws {
        try info(["CFBundleIdentifier": "org.example.editor"], at: app)
        let outside = root.rootURL.appendingPathComponent("outside.xpc")
        try info(["CFBundleIdentifier": "org.example.outside"], at: outside)
        let link = app.appendingPathComponent("Contents/XPCServices/Outside.xpc")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let (surface, capabilities) = read { _ in
            BundleSurfaceReader.Signature(gap: "Unsigned code.")
        }
        XCTAssertFalse(surface.bundleIdentifiers.contains("org.example.outside"))
        XCTAssertEqual(capabilities.unreadable, [link.path])
    }

    private struct FixedSurface: RegistrationSurface {
        let kind: Registration.Kind
        let result: RegistrationSnapshot
        func coverage(in _: FileSystemRoot) async -> RegistrationCoverage {
            result.coverage
        }

        func registrations(in _: FileSystemRoot) async -> [Registration] {
            result.registrations
        }

        func snapshot(in _: FileSystemRoot) async -> RegistrationSnapshot {
            result
        }
    }

    func testReportKeepsDeclarationAndReadStatusSeparateAndIsApprovedWithPlan() async throws {
        try info(["CFBundleIdentifier": "org.example.editor",
                  "NSExtension": ["NSExtensionPointIdentifier": "org.example.extension"]], at: app)
        let (surface, capabilities) = read { _ in
            BundleSurfaceReader.Signature(gap: "Ad-hoc signature.")
        }
        let identity = Identity(bundleID: "org.example.editor", name: "Editor")
            .attaching(surface, capabilities: capabilities)
        let empty = FixedSurface(kind: .appExtension,
                                 result: RegistrationSnapshot(registrations: [], coverage: .available(.appExtension)))
        let scanned = await CapabilitySearchScanner(surfaces: [empty])
            .scan(identity: identity, in: root, completeness: .complete)
        let report = try XCTUnwrap(scanned)
        let extensionCheck = try XCTUnwrap(report.checks.first { $0.capability == .appExtension })
        XCTAssertEqual(extensionCheck.declaration, .declared)
        XCTAssertTrue(extensionCheck.coverage.available)
        XCTAssertTrue(extensionCheck.registrations.isEmpty)
        let privacyCheck = try XCTUnwrap(report.checks.first { $0.capability == .privacyGrant })
        XCTAssertEqual(privacyCheck.declaration, .unknown)
        XCTAssertFalse(privacyCheck.coverage.available)
        XCTAssertEqual(privacyCheck.coverage.absence, .byDesign)

        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture",
                        osVersion: "fixture", intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                        steps: [], excludedItems: [], expectedTotalBytes: 0)
        let approved = plan.attaching(report)
        XCTAssertNotEqual(try approved.contentHash(), try plan.contentHash())
        XCTAssertEqual(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(approved)), approved)
        XCTAssertNil(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan)).capabilityReport)
    }

    func testFailedAndTimedOutSystemProbesAreNotEmptySuccesses() {
        XCTAssertNil(ToolOutput.read("/usr/bin/false", []))
        XCTAssertNil(ToolOutput.read("/bin/sleep", ["2"], timeout: 0.02))
    }
}
