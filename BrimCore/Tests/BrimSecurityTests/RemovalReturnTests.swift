import BrimCore
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

/// A confirmed removal looked at again later. Brim checked each removal once,
/// so files that came back afterwards (a helper still running, a sync, a
/// reinstall) left a removal reading as done when it had come undone.
struct RemovalReturnTests {
    @Test func `files still gone stay gone`() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let gone = folder.path("Application Support/Example")
        let (plan, entry) = removal([gone])
        #expect(RemovalReturn.paths(plan: plan, entry: entry) == [gone])
        #expect(RemovalReturn.paths(plan: plan, entry: entry).filter(RemovalReturn.isBack).isEmpty)
        #expect(RemovalReturn.state(back: [], plan: plan, installed: []) == .stillGone)
    }

    @Test func `a folder that came back is one row, not one per file inside it`() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let data = folder.path("Application Support/Example")
        let inside = data + "/state.json"
        let cache = folder.path("Caches/com.example.app")
        let (plan, entry) = removal([data, inside, cache])
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inside, contents: Data("{}".utf8))
        let back = RemovalReturn.outermost(RemovalReturn.paths(plan: plan, entry: entry).filter(RemovalReturn.isBack))
        #expect(back == [data])
        #expect(RemovalReturn.state(back: back, plan: plan, installed: []) == .cameBack([data]))
    }

    /// `cfprefsd` writes an empty file back for a domain it was holding.
    /// The removal's own check already allows it, and so does this one.
    @Test func `an empty preference file is not a return`() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let preferences = folder.path("Preferences")
        try FileManager.default.createDirectory(atPath: preferences, withIntermediateDirectories: true)
        let stub = preferences + "/com.example.app.plist"
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: stub))
        #expect(RemovalReturn.isBack(stub) == false)
        try PropertyListSerialization.data(fromPropertyList: ["Key": 1], format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: stub))
        #expect(RemovalReturn.isBack(stub))
    }

    /// The first check says what never went. Reviewing a removal that came
    /// back writes a later check naming those paths, and reading that one
    /// would turn them back into "still gone".
    @Test func `only the first check decides what never went`() {
        let kept = "/Users/example/Library/Caches/com.example.app"
        let taken = "/Users/example/Library/Application Support/Example"
        let (plan, base) = removal([kept, taken])
        var entry = base
        entry.verifications = [verification(entry.planId, remaining: [kept]),
                               verification(entry.planId, remaining: [kept, taken])]
        #expect(RemovalReturn.paths(plan: plan, entry: entry) == [taken])
    }

    @Test func `steps that keep something or failed are not asked about`() {
        let uninstaller = "/Applications/Example.app/Contents/Resources/Uninstall.app"
        let failed = "/Library/Application Support/Example"
        let taken = "/Users/example/Library/Preferences/com.example.app.plist"
        let steps = [
            step(0, .revealVendorUninstaller, uninstaller), step(1, .trashPathPrivileged, failed),
            step(2, .removeLaunchdPlist, taken)
        ]
        let plan = plan(steps)
        var entry = JournalEntry(planId: plan.planId, startedAt: Date(), status: .partial,
                                 stepOutcomes: [0: "ok", 1: "permission_denied", 2: "already_gone"])
        entry.verifications = [verification(plan.planId)]
        #expect(RemovalReturn.paths(plan: plan, entry: entry) == [taken])
    }

    @Test func `put back and unchecked removals are not looked at`() {
        var (_, entry) = removal(["/tmp/x"])
        #expect(RemovalReturn.isSettled(entry))
        entry.restoredAt = Date()
        #expect(RemovalReturn.isSettled(entry) == false)
        entry.restoredAt = nil
        entry.restoreOutcomes = [0: "restore_failed"]
        #expect(RemovalReturn.isSettled(entry) == false)
        entry.restoreOutcomes = nil
        entry.verifications = nil
        #expect(RemovalReturn.isSettled(entry) == false)
    }

    @Test func `a reinstall is not a removal coming undone`() {
        let (plan, _) = removal(["/Applications/Example.app"])
        let back = ["/Users/example/Library/Preferences/com.example.app.plist"]
        #expect(RemovalReturn.state(back: back, plan: plan, installed: ["com.example.app"]) == .installedAgain)
        #expect(RemovalReturn.state(back: back, plan: plan, installed: ["com.other.app"]) == .cameBack(back))
    }

    /// Removing one of two copies leaves the identifier installed, which
    /// says nothing about this removal.
    @Test func `a copy that stayed does not read as a reinstall`() {
        let identity = Identity(bundleID: "com.example.app", name: "Example")
        let removed = plan([step(0, .trashPath, "/Users/example/Applications/Example.app")],
                           surviving: [identity])
        let back = ["/Users/example/Library/Caches/com.example.app"]
        #expect(RemovalReturn.state(back: back, plan: removed, installed: ["com.example.app"]) == .cameBack(back))
        #expect(RemovalReturn.state(back: [], plan: removed, installed: ["com.example.app"]) == .stillGone)
    }

    @Test func `the app bundle itself coming back is a reinstall`() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let bundle = folder.path("Example.app")
        try FileManager.default.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
                                           format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        let (plan, _) = removal([bundle])
        #expect(RemovalReturn.state(back: [bundle], plan: plan, installed: []) == .installedAgain)
    }

    // MARK: - Fixtures

    private func removal(_ paths: [String]) -> (Plan, JournalEntry) {
        let plan = plan(paths.enumerated().map { step($0.offset, .trashPath, $0.element) })
        var outcomes: [Int: String] = [:]
        for index in paths.indices {
            outcomes[index] = "ok"
        }
        var entry = JournalEntry(planId: plan.planId, startedAt: Date(), status: .completed, stepOutcomes: outcomes)
        entry.verifications = [verification(plan.planId)]
        return (plan, entry)
    }

    private func step(_ index: Int, _ kind: StepKind, _ target: String) -> Step {
        Step(index: index, kind: kind, target: target, targetFingerprint: nil, tier: .A, evidence: "Fixture",
             expectedBytes: 0, capability: .ok, reversible: true, costOfError: .medium)
    }

    private func plan(_ steps: [Step], surviving: [Identity]? = nil) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
             intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.example.app",
                                                                            name: "Example")),
             steps: steps, excludedItems: [], expectedTotalBytes: 0, survivingCopies: surviving)
    }

    private func verification(_ id: UUID, remaining: Set<String> = []) -> VerificationResult {
        VerificationResult(planId: id, expectedBytes: 0, recoveredBytes: 0, success: remaining.isEmpty,
                           remainingPaths: remaining)
    }

    private struct Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("brim-return-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            url.appendingPathComponent(relative).path
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
