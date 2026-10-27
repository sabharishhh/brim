import BrimCore
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

struct RemovalPreviewTests {
    @Test func inspectionSelectionAndPreloadingReuseDiscoveryUntilInvalidation() async throws {
        let fixture = try PreviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let service = fixture.service()
        await service.preloadApplication(identity: fixture.identity, includeReview: true)
        let arrived = try fixture.cache("org.example.preview.new")
        let footprint = try await service.inspect(identity: fixture.identity)
        #expect(!footprint.items
            .contains { $0.evidence.url.resolvingSymlinksInPath() == arrived.resolvingSymlinksInPath() })
        let plan = try await service.plan(intent: fixture.intent)
        #expect(!paths(in: plan).contains(arrived.resolvingSymlinksInPath().path))
        await service.invalidateRemovalPreviews()
        let current = try await service.plan(intent: fixture.intent)
        #expect(paths(in: current).contains(arrived.resolvingSymlinksInPath().path))
    }

    /// A fast preview must not become a shortcut around apply's independent
    /// revalidation. The newly arrived path changes the approved footprint.
    @Test func cachedReviewStillRequiresFreshDiscoveryBeforeExecution() async throws {
        let fixture = try PreviewFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let service = fixture.service()
        let plan = try await service.plan(intent: fixture.intent)
        let token = try await service.approvedToken(planId: plan.planId, requester: plan.intent.requesterIdentity)
        let arrived = try fixture.cache("org.example.preview.new")
        do {
            try await service.apply(planId: plan.planId, token: token)
            Issue.record("A stale preview was executed without fresh discovery.")
        } catch let error as BrimService.ApplyError {
            guard case .validationFailed = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.app.path))
        #expect(FileManager.default.fileExists(atPath: arrived.path))
    }

    private func paths(in plan: Plan) -> Set<String> {
        Set(plan.steps.map { URL(fileURLWithPath: $0.target).resolvingSymlinksInPath().path })
    }
}

private struct PreviewFixture {
    let folder: URL
    let root: FileSystemRoot
    let app: URL
    var identity: Identity {
        Identity(bundleID: "org.example.preview", name: "Editor", bundlePath: app.path)
    }

    var intent: PlanIntent {
        PlanIntent(type: .uninstall, subjectIdentity: identity)
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = FileSystemRoot(rootURL: folder.appendingPathComponent("Root"), userName: "tester")
        app = root.url(for: .applications).appendingPathComponent("Editor.app")
        let metadata = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.preview"],
                                           format: .xml, options: 0).write(to: metadata)
    }

    func cache(_ name: String) throws -> URL {
        let url = root.url(for: .userCaches).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: url.appendingPathComponent("data"))
        return url
    }

    func service() -> BrimService {
        BrimService(root: root, brimAppURL: folder.appendingPathComponent("Brim.app"),
                    planStoreDirectory: folder.appendingPathComponent("Plans"),
                    journalStoreDirectory: folder.appendingPathComponent("Journals"))
    }
}
