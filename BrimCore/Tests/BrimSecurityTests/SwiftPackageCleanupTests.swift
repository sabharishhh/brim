import BrimCore
@testable import BrimOps
import BrimProtocol
@testable import BrimService
import Foundation
import Synchronization
import Testing

struct SwiftPackageCleanupTests {
    @Test func scopedPackageCleanupPassesApprovalAndInvokesOnlyTheReviewedTool() async throws {
        let fixture = try Fixture()
        let invoked = Mutex<[ToolCleanupBinding]>([])
        let client = fixture.client { binding, _ in invoked.withLock { $0.append(binding) } }
        let service = BrimService(
            root: FileSystemRoot(rootURL: fixture.root, userName: "tester"),
            brimAppURL: fixture.root.appendingPathComponent("Brim.app"),
            planStoreDirectory: fixture.root.appendingPathComponent("Plans"),
            journalStoreDirectory: fixture.root.appendingPathComponent("Journals"),
            consent: ConsentSource { _ in true }, automatedConsentAllowed: false,
            toolCleanupClient: client
        )
        let request = try client.request(id: "swiftpm.cache")
        let plan = try await service.planToolCleanup(id: request.id.rawValue, cachePath: request.cachePath)
        let binding = try #require(plan.toolCleanupBinding)
        #expect(binding.id == .swiftPM)
        #expect(binding.arguments.last == "purge-cache")
        #expect(binding.arguments.filter { $0 == fixture.cache.path }.count == 5)
        #expect(!binding.arguments.contains("reset"))
        try await service.approveAndApply(planId: plan.planId, requesterIdentity: plan.intent.requesterIdentity)
        #expect(invoked.withLock { $0 } == [binding])
        let result = try await service.verify(planId: plan.planId)
        #expect(result.toolCleanup?.state == .completed)
        #expect(result.expectedBytes == 0 && result.recoveredBytes == 0)
    }

    @Test func unknownSwiftVersionsAndUnboundInvocationAreRefusedBeforeDispatch() async throws {
        let fixture = try Fixture()
        let invoked = Mutex(false)
        let client = fixture
            .client(version: "Swift Package Manager - Swift 6.1.0") { _, _ in invoked.withLock { $0 = true } }
        let request = try client.request(id: "swiftpm.cache")
        await #expect(throws: ToolCleanup.CleanupError.self) { _ = try await client.prepare(request) }
        await #expect(throws: ToolCleanup.CleanupError.self) {
            try await ToolCleanup.run(id: "swiftpm.cache", runner: { _, _ in invoked.withLock { $0 = true }; return 0 })
        }
        #expect(!invoked.withLock { $0 })
    }

    @Test(arguments: ["manifests", "registry", "registry/downloads", "CACHEDIR.TAG"])
    func cacheLinksCannotWidenTheNativeOperation(relative: String) async throws {
        let fixture = try Fixture()
        let outside = fixture.home.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.cache.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let client = fixture.client { _, _ in Issue.record("Refused cache must not run") }
        let request = try client.request(id: "swiftpm.cache")
        await #expect(throws: ToolCleanup.CleanupError.self) { _ = try await client.prepare(request) }
    }

    @Test func aCacheRootLinkCannotRedirectTheNativeOperation() async throws {
        let fixture = try Fixture()
        let outside = fixture.home.appendingPathComponent("another-cache")
        try FileManager.default.moveItem(at: fixture.cache, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.cache, withDestinationURL: outside)
        let client = fixture.client { _, _ in Issue.record("Redirected cache must not run") }
        let request = try client.request(id: "swiftpm.cache")
        await #expect(throws: ToolCleanup.CleanupError.self) { _ = try await client.prepare(request) }
    }

    @Test(arguments: ["Library", "Library/Caches", "Library/Caches/org.swift.swiftpm"])
    func linksIntroducedDuringToolProbesCannotRedirectTheApprovedScope(relative: String) async throws {
        let fixture = try Fixture()
        let client = ToolCleanup.Client(
            environment: { fixture.environment },
            query: { _, arguments, _, _ in
                guard arguments == ["--version"] else { return fixture.executable.path }
                let original = fixture.home.appendingPathComponent(relative)
                let moved = fixture.home.appendingPathComponent("redirected")
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
                return "Swift Package Manager - Swift 6.4.0-dev"
            },
            invoke: { _, _ in Issue.record("A redirected scope must not run") }
        )
        let request = try client.request(id: "swiftpm.cache")
        await #expect(throws: ToolCleanup.CleanupError.configurationUnavailable(
            "A package cache path is a link or is no longer a folder. Manage this cache in Xcode."
        )) {
            _ = try await client.prepare(request)
        }
    }

    @Test func changedPackageBinaryStillInvalidatesTheBinding() async throws {
        let fixture = try Fixture()
        let invoked = Mutex(false)
        let client = fixture.client { _, _ in invoked.withLock { $0 = true } }
        let request = try client.request(id: "swiftpm.cache")
        let approved = try await client.prepare(request)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture.executable)
        await #expect(throws: ToolCleanup.CleanupError.bindingChanged) {
            try await client.run(approved, request: request)
        }
        #expect(!invoked.withLock { $0 })
    }

    /// The installed native command touches only controlled temporary cache files.
    @Test func nativePackageToolPurgesFixtureCachesWithoutChangingProjectOrSDKContent() async throws {
        let fixture = try Fixture()
        for path in [
            "repositories/package/contents",
            "manifests/example",
            "registry/downloads/example",
            "artifacts/keep",
            "prebuilts/keep"
        ] {
            let url = fixture.cache.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: url)
        }
        let project = fixture.home.appendingPathComponent("Project/.build/keep")
        try FileManager.default.createDirectory(
            at: project.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("project".utf8).write(to: project)
        let client = ToolCleanup.Client(environment: { fixture.environment })
        let request = try client.request(id: "swiftpm.cache")
        let approved = try await client.prepare(request)
        try await client.run(approved, request: request)
        #expect(!FileManager.default
            .fileExists(atPath: fixture.cache.appendingPathComponent("repositories/package").path))
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("artifacts/keep").path))
        #expect(FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("prebuilts/keep").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".build").path))
    }

    private final class Fixture: Sendable {
        let root: URL
        let home: URL
        let cache: URL
        let executable: URL
        let environment: [String: String]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-cache-\(UUID().uuidString)")
            home = root.appendingPathComponent("Home with spaces")
            cache = home.appendingPathComponent("Library/Caches/org.swift.swiftpm")
            executable = root.appendingPathComponent("swift-package")
            environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
        func client(
            version: String = "Swift Package Manager - Swift 6.4.0-dev",
            invoke: @escaping @Sendable (ToolCleanupBinding, [String: String]) async throws -> Void
        ) -> ToolCleanup.Client {
            ToolCleanup.Client(
                environment: { [self] in environment },
                query: { [self] _, arguments, _, _ in
                    arguments == ["--version"] ? version : executable.path
                },
                invoke: invoke
            )
        }
    }
}
