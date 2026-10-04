@testable import BrimCore
@testable import BrimService
import Foundation
import Testing

struct SurvivingCopyRevalidationTests {
    /// A new installation between review and apply must protect the state
    /// it now shares, before any removal or privacy reset is executed.
    @Test func newlyInstalledCopyInvalidatesApprovedRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"), userName: "tester")
        func bundle(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.example.copytest", "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        let selected = root.url(for: .applications).appendingPathComponent("Editor.app")
        try bundle(selected)
        let preferences = root.url(for: .userPreferences).appendingPathComponent("org.example.copytest.plist")
        try FileManager.default.createDirectory(
            at: preferences.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep these settings".utf8).write(to: preferences)
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: directory.appendingPathComponent("Plans"),
                                  journalStoreDirectory: directory.appendingPathComponent("Journals"))
        let identity = Identity(bundleID: "org.example.copytest", name: "Editor", bundlePath: selected.path)
        let plan = try await service.plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(plan.steps.contains { $0.kind == .resetPrivacyGrants })
        let token = try await service.tokenStore.mintToken(planId: plan.planId, planHash: plan.contentHash(),
                                                           requesterIdentity: plan.intent.requesterIdentity)
        let other = root.url(for: .userApplications).appendingPathComponent("Editor Beta.app")
        try bundle(other)
        do {
            try await service.apply(planId: plan.planId, token: token)
            Issue.record("The removal accepted newly shared state")
        } catch let error as BrimService.ApplyError {
            guard case .validationFailed = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try Data(contentsOf: preferences) == Data("keep these settings".utf8))
        #expect(!FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("Journals/\(plan.planId.uuidString).journal").path))
    }
}
