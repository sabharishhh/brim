import BrimCore
@testable import BrimOps
import BrimProtocol
@testable import BrimService
import Foundation
import Synchronization
import Testing

struct DelegatedCleanupPlanTests {
    /// Tool approval used to re-plan a command string as an application.
    @Test func rebuildsTheSameCleanupWithoutAnApplicationSearch() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let service = fixture.service()
        let initial = try await service.planToolCleanup(id: "npm.cache", displayed: "caller supplied lie")
        let rebuilt = try await service.plan(intent: initial.intent)
        #expect(rebuilt.steps == initial.steps)
        #expect(rebuilt.toolCleanupBinding == initial.toolCleanupBinding)
        #expect(rebuilt.capabilityReport == nil)
        #expect(initial.intent.type == .toolCleanup)
        #expect(!initial.steps[0].evidence.contains("caller supplied lie"))
    }

    @Test(arguments: ["npm.cache", "go.modcache", "pip.cache"])
    func approvalRunsOnlyTheRebuiltScopedCommandOnce(id: String) async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let asked = Mutex(0)
        let service = fixture.service(consent: ConsentSource { _ in asked.withLock { $0 += 1 }; return true })
        let plan = try await service.planToolCleanup(id: id, displayed: "ignored")
        let before = try await service.verify(planId: plan.planId)
        #expect(before.toolCleanup?.state == .notRun)
        #expect(!before.success)
        let receipt = try await service.requestApproval(
            planId: plan.planId,
            requesterIdentity: plan.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        try await service.apply(planId: plan.planId, token: token)
        #expect(asked.withLock { $0 } == 1)
        let invocations = fixture.invocations.withLock { $0 }
        #expect(invocations.count == 1)
        #expect(invocations.first == plan.toolCleanupBinding)
        #expect(plan.steps[0].evidence.hasPrefix(invocations[0].displayed))
        let result = try await service.verify(planId: plan.planId)
        #expect(result.success)
        #expect(result.toolCleanup?.state == .completed)
        #expect(result.toolCleanup?.headline == "Command completed")
        #expect(result.report == nil)
        #expect(result.expectedBytes == 0 && result.recoveredBytes == 0)
        #expect(result.toolCleanup?.detail.contains("has not verified") == true)
        await #expect(throws: TokenStore.TokenError.notFound) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(fixture.invocations.withLock { $0.count } == 1)
    }

    @Test(arguments: ["unknown", "homebrew.cleanup", "pnpm.store", "uv.cache", "xcode.simulators"])
    func unsupportedAndUnsafeScopesNeverReachApproval(id: String) async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        await #expect(throws: ToolCleanup.CleanupError.self) {
            _ = try await fixture.service().planToolCleanup(id: id, displayed: "harmless")
        }
        #expect(fixture.invocations.withLock { $0.isEmpty })
    }

    @Test(arguments: ["configuration", "executable", "scope", "environment", "policy", "display"])
    func changesAfterApprovalRefuseBeforeDispatchOrJournal(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let service = fixture.service()
        let plan = try await service.planToolCleanup(id: "npm.cache", displayed: "ignored")
        let receipt = try await service.requestApproval(
            planId: plan.planId,
            requesterIdentity: plan.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        switch change {
        case "configuration": fixture.configuration.withLock { $0["npm"] = fixture.directory.path }
        case "executable": try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture.bin.appendingPathComponent("npm"))
        case "scope":
            let old = fixture.home.appendingPathComponent(".npm")
            try FileManager.default.moveItem(at: old, to: fixture.home.appendingPathComponent(".npm-old"))
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        case "environment": fixture.environment.withLock { $0["LANG"] = "C" }
        case "policy", "display":
            let altered = try changing(plan, field: change == "policy" ? "catalogueRevision" : "displayed")
            try altered.canonicalData().write(to: fixture.planFile(altered.planId), options: .atomic)
        default: Issue.record("Unknown fixture change")
        }
        await #expect(throws: (any Error).self) { try await service.apply(planId: plan.planId, token: token) }
        #expect(fixture.invocations.withLock { $0.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: fixture.journal(plan.planId).path))
    }

    /// Approval may cover the altered stored policy. Independent rebuilding must still refuse it.
    @Test func newlyApprovedAlteredPolicyCannotDefineAnOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let service = fixture.service()
        let original = try await service.planToolCleanup(id: "npm.cache", displayed: "ignored")
        let altered = try changing(original, field: "catalogueRevision")
        #expect(try original.contentHash() != altered.contentHash())
        try altered.canonicalData().write(to: fixture.planFile(altered.planId), options: .atomic)
        let receipt = try await service.requestApproval(
            planId: altered.planId,
            requesterIdentity: altered.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        await #expect(throws: BrimService.ApplyError.self) {
            try await service.apply(planId: altered.planId, token: token)
        }
        #expect(fixture.invocations.withLock { $0.isEmpty })
    }

    @Test func expiredApprovalCannotRunTheCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let time = Mutex(Date())
        let tokens = TokenStore(currentTime: { time.withLock { $0 } })
        let service = fixture.service(tokens: tokens)
        let plan = try await service.planToolCleanup(id: "npm.cache", displayed: "ignored")
        let receipt = try await service.requestApproval(
            planId: plan.planId,
            requesterIdentity: plan.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        time.withLock { $0 += 301 }
        await #expect(throws: TokenStore.TokenError.expired) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(fixture.invocations.withLock { $0.isEmpty })
    }

    @Test func failedCommandIsJournalledWithoutClaimingAbsence() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let service = fixture.service(fail: true)
        let plan = try await service.planToolCleanup(id: "npm.cache", displayed: "ignored")
        try await service.approveAndApply(planId: plan.planId, requesterIdentity: plan.intent.requesterIdentity)
        let result = try await service.verify(planId: plan.planId)
        #expect(!result.success)
        #expect(result.toolCleanup?.state == .failed)
        #expect(result.toolCleanup?.detail.contains("status 23") == true)
        let journal = try await JournalStore(directoryURL: fixture.directory.appendingPathComponent("Journals"))
            .load(planId: plan.planId)
        #expect(journal?.status == .partial)
    }

    /// Exercise real spawn, argv and cwd without calling an installed package manager.
    @Test func realFixtureToolReceivesTheReviewedArgumentsAndHomeDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let script = """
        #!/bin/sh
        if [ "$1" = "config" ]; then
            printf '%s\\n' "$HOME/.npm"
        else
            printf '%s\\n' "$PWD" "$@" > "$HOME/invocation.txt"
        fi
        """
        try Data(script.utf8).write(to: fixture.bin.appendingPathComponent("npm"))
        let client = ToolCleanup.Client(environment: { fixture.environment.withLock { $0 } })
        let request = try client.request(id: "npm.cache")
        let binding = try await client.prepare(request)
        try await client.run(binding, request: request)
        let observed = try String(contentsOf: fixture.home.appendingPathComponent("invocation.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(Array(observed.dropFirst()) == binding.arguments)
        var actualDirectory = stat()
        var expectedDirectory = stat()
        #expect(stat(observed[0], &actualDirectory) == 0)
        #expect(stat(fixture.home.path, &expectedDirectory) == 0)
        #expect(actualDirectory.st_dev == expectedDirectory.st_dev
            && actualDirectory.st_ino == expectedDirectory.st_ino)
        #expect(binding.arguments == ["--cache", fixture.home.appendingPathComponent(".npm").path,
                                      "cache", "clean", "--force"])
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".npm").path))
    }

    private func changing(_ plan: Plan, field: String) throws -> Plan {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var binding = try #require(json["toolCleanupBinding"] as? [String: Any])
        binding[field] = "changed"
        json["toolCleanupBinding"] = binding
        return try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private final class Fixture: Sendable {
        let directory: URL
        let home: URL
        let bin: URL
        let environment: Mutex<[String: String]>
        let configuration: Mutex<[String: String]>
        let invocations = Mutex<[ToolCleanupBinding]>([])

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            home = directory.appendingPathComponent("Home with spaces")
            bin = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            var paths: [String: String] = [:]
            for (tool, path) in [("npm", ".npm"), ("go", "go/pkg/mod"), ("pip", "Library/Caches/pip")] {
                let executable = bin.appendingPathComponent(tool)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                let cache = home.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                paths[tool] = cache.path
            }
            configuration = Mutex(paths)
            environment = Mutex(["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"])
        }

        func service(
            consent: ConsentSource = ConsentSource { _ in true },
            fail: Bool = false,
            tokens: TokenStore = .init()
        ) -> BrimService {
            let client = ToolCleanup.Client(
                environment: { [self] in environment.withLock { $0 } },
                query: { [self] executable, _, _, _ in
                    configuration.withLock { $0[(executable as NSString).lastPathComponent] ?? "" }
                },
                invoke: { [self] binding, _ in
                    if fail {
                        throw ToolCleanup.CleanupError.failed(binding.displayed, code: 23)
                    }
                    invocations.withLock { $0.append(binding) }
                }
            )
            return BrimService(
                root: FileSystemRoot(rootURL: directory, userName: "tester"),
                brimAppURL: directory.appendingPathComponent("Brim.app"),
                planStoreDirectory: directory.appendingPathComponent("Plans"),
                journalStoreDirectory: directory.appendingPathComponent("Journals"),
                consent: consent,
                automatedConsentAllowed: false,
                toolCleanupClient: client,
                tokenStore: tokens
            )
        }

        func planFile(_ id: UUID) -> URL {
            directory.appendingPathComponent("Plans/\(id.uuidString).json")
        }

        func journal(_ id: UUID) -> URL {
            directory.appendingPathComponent("Journals/\(id.uuidString).journal")
        }

        func destroy() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

struct DelegatedCleanupWireTests {
    @Test func oldPlanAndResultPayloadsStillDecodeAndOmitNewFields() throws {
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Old"))
        let old = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "old",
            osVersion: "old",
            intent: intent,
            steps: [],
            excludedItems: [],
            expectedTotalBytes: 0
        )
        let data = try JSONEncoder().encode(old)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("toolCleanup"))
        #expect(try JSONDecoder().decode(Plan.self, from: data) == old)
        let result = VerificationResult(planId: old.planId, expectedBytes: 0, recoveredBytes: 0, success: true)
        let resultData = try JSONEncoder().encode(result)
        let resultText = try #require(String(data: resultData, encoding: .utf8))
        #expect(!resultText.contains("toolCleanup"))
        #expect(try JSONDecoder().decode(VerificationResult.self, from: resultData) == result)
    }
}
