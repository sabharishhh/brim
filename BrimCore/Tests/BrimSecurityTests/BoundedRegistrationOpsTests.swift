import BrimCore
@testable import BrimOps
@testable import BrimProcess
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces
struct BoundedRegistrationOpsTests {
    @Test(arguments: [BrimProcess.NativeCommandRunner.Termination.timedOut, .cancelled, .signalled(9)])
    func unfinishedCommandsCannotBecomeAcceptedReceipts(
        _ termination: BrimProcess.NativeCommandRunner.Termination
    ) async {
        await #expect(throws: RegistrationCommand.Failure.self) {
            _ = try await RegistrationCommand.status("/fixture/tool", []) { _, _ in Self.result(termination) }
        }
    }

    @Test(arguments: ["failed", "truncated", "invalidUtf8"])
    func incompleteReadsCannotBecomeAnEmptyListing(_ scenario: String) async {
        await #expect(throws: RegistrationCommand.Failure.self) {
            _ = try await RegistrationCommand.read("/fixture/tool", []) { _, _ in
                BrimProcess.NativeCommandRunner.Result(termination: .exited(scenario == "failed" ? 1 : 0),
                                                       stdout: scenario == "invalidUtf8" ? Data([0xFF]) : Data(),
                                                       stderr: Data(), outputTruncated: scenario == "truncated")
            }
        }
    }

    @Test func anAlreadyAbsentJobDoesNotProduceAStoppedReceipt() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let script = RegistrationCommandScript([Self.result(), Self.absentResult])
        let stopped = try await SafeOps.stopLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                       runner: { executable, arguments in
                                                           try await script.invoke(executable, arguments)
                                                       })
        #expect(stopped == false)
        let calls = await script.calls
        #expect(calls.allSatisfy { $0.first == "print" })
        #expect(calls.count == 2)
    }

    @Test(arguments: ["failedBootout", "failedPostcheck", "ambiguousPath", "mismatchedProgram"])
    func aStopMustMatchTheDeclarationAndConfirmAbsence(_ scenario: String) async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let path = "path = " + fixture.declaration.path + "\nprogram = /fixture/helper"
        let output = scenario == "mismatchedProgram"
            ? path.replacingOccurrences(of: "/fixture/helper", with: "/fixture/other-helper") : path
        let loaded = Self.result(stdout: scenario == "ambiguousPath" ? output + "\n" + output : output)
        let responses = [Self.result(), Self.result(), loaded,
                         Self.result(.exited(scenario == "failedBootout" ? 5 : 0)),
                         Self.result(), Self.result(.exited(1))]
        let script = RegistrationCommandScript(responses)
        await #expect(throws: (any Error).self) {
            _ = try await SafeOps.stopLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                 runner: { executable, arguments in
                                                     try await script.invoke(executable, arguments)
                                                 })
        }
        if scenario == "failedPostcheck" {
            let receipt = await script.calls
            #expect(receipt.contains(where: { $0.first == "bootout" }))
        }
        if scenario == "ambiguousPath" || scenario == "mismatchedProgram" {
            let calls = await script.calls
            #expect(calls.contains(where: { $0.first == "bootout" }) == false)
        }
    }

    @Test func aVerifiedStopReturnsAReceiptForOnlyTheExactService() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let script = RegistrationCommandScript([
            Self.result(), Self.result(),
            Self.result(stdout: "path = " + fixture.declaration.path + "\nprogram = /fixture/helper"),
            Self.result(), Self.result(), Self.absentResult
        ])
        let stopped = try await SafeOps.stopLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                       runner: { executable, arguments in
                                                           try await script.invoke(executable, arguments)
                                                       })
        #expect(stopped)
        let calls = await script.calls
        #expect(calls.filter { $0.first == "bootout" } == [["bootout", Self.namespace + "/org.example.fixture"]])
    }

    @Test func bootstrapAcceptanceDoesNotProveTheReviewedJobWasRestored() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let script = RegistrationCommandScript([
            Self.result(), Self.absentResult, Self.result(),
            Self.result(stdout: "path = /other/job.plist")
        ])
        await #expect(throws: (any Error).self) {
            try await SafeOps.restoreLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                runner: { executable, arguments in
                                                    try await script.invoke(executable, arguments)
                                                })
        }
    }

    @Test func failedStopObservationStillRecordsCommandCompletion() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let script = RegistrationCommandScript([
            Self.result(), Self.result(),
            Self.result(stdout: "path = " + fixture.declaration.path + "\nprogram = /fixture/helper"),
            Self.result(), Self.result(.exited(1))
        ])
        await #expect(throws: LaunchdStopError.self) {
            _ = try await SafeOps.stopLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                 runner: { executable, arguments in
                                                     try await script.invoke(executable, arguments)
                                                 })
        }
    }

    @Test(arguments: ["matching", "replacement", "unreadable"])
    func restorationRetryOnlyAcceptsThePreviouslyRestoredJob(_ scenario: String) async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let program = scenario == "replacement" ? "/fixture/other-helper" : "/fixture/helper"
        let loaded = Self.result(stdout: "path = " + fixture.declaration.path + "\nprogram = " + program,
                                 truncated: scenario == "unreadable")
        let script = RegistrationCommandScript([Self.result(), Self.result(), loaded])
        if scenario == "matching" {
            try await SafeOps.restoreLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                runner: { executable, arguments in
                                                    try await script.invoke(executable, arguments)
                                                })
        } else {
            await #expect(throws: (any Error).self) {
                try await SafeOps.restoreLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                                    runner: { executable, arguments in
                                                        try await script.invoke(executable, arguments)
                                                    })
            }
        }
        let calls = await script.calls
        #expect(calls.allSatisfy { $0.first == "print" })
    }

    @Test func absentJobRestorationBootstrapsAndChecksTheExactDeclaration() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let script = RegistrationCommandScript([
            Self.result(), Self.absentResult, Self.result(),
            Self.result(stdout: "path = " + fixture.declaration.path + "\nprogram = /fixture/helper")
        ])
        try await SafeOps.restoreLaunchdJob(path: fixture.declaration.path, namespace: Self.namespace,
                                            runner: { executable, arguments in
                                                try await script.invoke(executable, arguments)
                                            })
        let calls = await script.calls
        #expect(calls.filter { $0.first == "bootstrap" } == [["bootstrap", Self.namespace, fixture.declaration.path]])
    }

    @Test(arguments: ["matching", "replacementPath", "replacementProgram", "ambiguous", "unreadable", "absent"])
    func reviewedJobRechecksUseDeclarationAndProgram(_ scenario: String) async {
        let record = Registration(kind: .launchdJob, identifier: "org.example.fixture", label: "Fixture",
                                  programPath: "/fixture/Original.app/helper", targetExists: true,
                                  recordPath: "/fixture/job.plist", evidence: "Reviewed declaration.",
                                  namespace: Self.namespace)
        let path = scenario == "replacementPath" ? "/fixture/other.plist" : "/fixture/job.plist"
        let program = scenario == "replacementProgram"
            ? "/fixture/Replacement.app/helper" : "/fixture/Original.app/helper"
        var output = "path = " + path + "\nprogram = " + program
        if scenario == "ambiguous" {
            output += "\npath = /fixture/other.plist"
        }
        let response = scenario == "absent" ? Self.absentResult
            : Self.result(stdout: output, truncated: scenario == "unreadable")
        let script = RegistrationCommandScript([Self.result(), response])
        let observation = await SafeOps.observeLoadedReviewedJob(record, runner: { executable, arguments in
            try await script.invoke(executable, arguments)
        })
        switch scenario {
        case "matching": #expect(observation.isPresent)
        case "replacementPath", "replacementProgram", "absent": #expect(observation.isAbsent)
        default: #expect(observation.isUnknown)
        }
    }

    @Test func anUnavailableDomainCannotProveAJobIsAbsent() async {
        let script = RegistrationCommandScript([Self.result(.exited(1)), Self.absentResult])
        let observation = await SafeOps.observeLaunchdService(label: "org.example.fixture", namespace: Self.namespace,
                                                              runner: { executable, arguments in
                                                                  try await script.invoke(executable, arguments)
                                                              })
        #expect(observation.isUnknown)
        let calls = await script.calls
        #expect(calls.count == 1)
    }
}

extension BoundedRegistrationOpsTests {
    @Test(arguments: ["stop", "restore"])
    func declarationChangesDuringRuntimeChecksNeverReachMutation(_ operation: String) async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let declaration = fixture.declaration
        let loaded = Self.result(stdout: "path = " + declaration.path + "\nprogram = /fixture/helper")
        let script = RegistrationCommandScript(operation == "stop"
            ? [Self.result(), Self.result(), loaded] : [Self.result(), Self.absentResult])
        let mutationPoint = operation == "stop" ? 3 : 2
        let runner: RegistrationCommand.Runner = { executable, arguments in
            let result = try await script.invoke(executable, arguments)
            if await script.calls.count == mutationPoint {
                // Append in place so inode-only checks cannot catch the change.
                let handle = try FileHandle(forWritingTo: declaration)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
            }
            return result
        }
        await #expect(throws: (any Error).self) {
            if operation == "stop" {
                _ = try await SafeOps.stopLaunchdJob(path: declaration.path, namespace: Self.namespace, runner: runner)
            } else {
                try await SafeOps.restoreLaunchdJob(path: declaration.path, namespace: Self.namespace, runner: runner)
            }
        }
        let calls = await script.calls
        #expect(calls.allSatisfy { $0.first == "print" })
    }

    @Test func aDeclarationChangedAfterBootoutKeepsACommandReceiptWithoutConfirmingRemoval() async throws {
        let fixture = try RegistrationOpsFixture()
        defer { fixture.remove() }
        let declaration = fixture.declaration
        let script = RegistrationCommandScript([
            Self.result(), Self.result(),
            Self.result(stdout: "path = " + declaration.path + "\nprogram = /fixture/helper"),
            Self.result(), Self.result(), Self.absentResult
        ])
        await #expect(throws: LaunchdStopError.self) {
            _ = try await SafeOps.stopLaunchdJob(path: declaration.path, namespace: Self.namespace,
                                                 runner: { executable, arguments in
                                                     let result = try await script.invoke(executable, arguments)
                                                     if await script.calls.count == 6 {
                                                         let handle = try FileHandle(forWritingTo: declaration)
                                                         defer { try? handle.close() }
                                                         try handle.seekToEnd()
                                                         try handle.write(contentsOf: Data("\n".utf8))
                                                     }
                                                     return result
                                                 })
        }
    }

    @Test func compatibilityMutatorsKeepTheirInjectedScopedRunner() async throws {
        let path = "/fixture/Example With Spaces.app"
        try await LaunchServicesRegistration.unregister(bundlePath: path) { executable, arguments in
            #expect(executable == LaunchServicesRegistration.lsregisterPath)
            #expect(arguments == ["-u", path])
            return 0
        }
        await #expect(throws: LaunchServicesRegistration.UnregisterError.self) {
            try await LaunchServicesRegistration.register(bundlePath: path) { _, arguments in
                #expect(arguments == ["-f", path])
                return 1
            }
        }
    }

    @Test(arguments: ["/", "relative.app", "\0"])
    func invalidBundlePathsNeverReachTheRunner(_ path: String) async {
        await #expect(throws: LaunchServicesRegistration.UnregisterError.self) {
            try await LaunchServicesRegistration.unregister(bundlePath: path) { _, _ in
                Issue.record("An invalid path reached the registration command.")
                return 0
            }
        }
    }

    @Test func injectedLegacyRuntimeClosuresStillWork() async throws {
        let runtime = LaunchdRuntimeClient(stop: { _ in }, restore: { _ in }, observe: { _, _ in .absent })
        #expect(try await runtime.stopWithReceipt("/fixture/job.plist"))
        let record = Registration(kind: .launchdJob, identifier: "org.example.fixture", label: "Fixture",
                                  targetExists: false, evidence: "Fixture", namespace: Self.namespace)
        #expect(await runtime.observeReviewed(record).isAbsent)
    }

    private static var namespace: String {
        "gui/\(getuid())"
    }

    private static var absentResult: BrimProcess.NativeCommandRunner.Result {
        result(.exited(113), stderr: "Could not find service")
    }

    private static func result(
        _ termination: BrimProcess.NativeCommandRunner.Termination = .exited(0),
        stdout: String = "", stderr: String = "", truncated: Bool = false
    ) -> BrimProcess.NativeCommandRunner.Result {
        BrimProcess.NativeCommandRunner.Result(
            termination: termination, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), outputTruncated: truncated
        )
    }
}

private actor RegistrationCommandScript {
    var calls: [[String]] = []
    private var responses: [BrimProcess.NativeCommandRunner.Result]

    init(_ responses: [BrimProcess.NativeCommandRunner.Result]) {
        self.responses = responses
    }

    func invoke(_ executable: String, _ arguments: [String]) throws -> BrimProcess.NativeCommandRunner.Result {
        #expect(executable == "/bin/launchctl")
        calls.append(arguments)
        guard !responses.isEmpty else {
            Issue.record("The helper ran an unexpected command.")
            throw NSError(domain: "Fixture", code: 1)
        }
        return responses.removeFirst()
    }
}

private struct RegistrationOpsFixture {
    let base: URL
    let declaration: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("brim-registration-ops-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        declaration = base.appendingPathComponent("fixture.plist")
        let plist = ["Label": "org.example.fixture", "Program": "/fixture/helper"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: declaration)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
