import BrimCore
import BrimProtocol
@testable import BrimUI
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces

/// When Brim installs something itself, it also finishes the recording
/// itself: what is linked to the install is kept without asking, and the
/// person is asked only about what nothing links to it.
@MainActor
struct InstallRecordingModelTests {
    private let app = RecordedApp(name: "Demo", bundleID: "com.vendorco.demo", path: "/Applications/Demo.app",
                                  version: "1", wasUpdated: false, names: ["Demo"])

    private func result(apps: [RecordedApp], linked: [RecordedItem] = [],
                        unclaimed: [RecordedItem] = []) -> InstallRecordingResult {
        InstallRecordingResult(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60),
                               apps: apps, linked: linked, unclaimed: unclaimed, otherApps: [:], unreadable: [])
    }

    @Test func `everything linked is kept without asking`() async {
        let linked = RecordedItem(path: "/Users/me/Library/Application Support/Demo", why: "Named for Demo",
                                  app: app.path)
        let service = RecordingStub(result: result(apps: [app], linked: [linked]))
        let model = InstallRecordingModel()
        await model.start(service: service)
        await model.finishOnItsOwn()
        #expect(model.phase == .idle)
        #expect(model.keptQuietly?.items == [linked])
        #expect(await service.kept.first?.apps == [app])
    }

    /// Nobody starts a recording, so nobody is asked to judge one: what
    /// links to the install is kept and anything else is left out.
    @Test func `something nothing links is left out without asking`() async {
        let linked = RecordedItem(path: "/Users/me/Library/Application Support/Demo", why: "Named for Demo",
                                  app: app.path)
        let stray = RecordedItem(path: "/Users/me/.stray", why: "Appeared while recording", app: nil)
        let service = RecordingStub(result: result(apps: [app], linked: [linked], unclaimed: [stray]))
        let model = InstallRecordingModel()
        await model.start(service: service)
        await model.finishOnItsOwn()
        #expect(model.phase == .idle)
        #expect(await service.kept.first?.items == [linked])
    }

    @Test func `an install that put nothing down records nothing`() async {
        let service = RecordingStub(result: result(apps: []))
        let model = InstallRecordingModel()
        await model.start(service: service)
        await model.finishOnItsOwn()
        #expect(model.phase == .idle)
        #expect(model.notice != nil)
        #expect(await service.cancelled)
    }

    @Test func `only what Brim can put in place offers Install`() {
        let signature = InstallerSignature(signer: nil, team: nil, verdict: .notarized)
        func app(installed: Bool) -> InstallerPreview {
            InstallerPreview(source: URL(fileURLWithPath: "/tmp/Demo.app"), kind: .application, name: "Demo",
                             signature: signature, apps: [.init(name: "Demo", identifier: "com.vendorco.demo",
                                                                version: "1", path: "/tmp/Demo.app",
                                                                isInstalled: installed)])
        }
        func image(_ contents: [InstallerPreview]) -> InstallerPreview {
            InstallerPreview(source: URL(fileURLWithPath: "/tmp/Demo.dmg"), kind: .diskImage, name: "Demo",
                             signature: signature, contents: contents)
        }
        let package = InstallerPreview(source: URL(fileURLWithPath: "/tmp/Demo.pkg"), kind: .package, name: "Demo",
                                       signature: signature)
        #expect(InstallRecordingModel.installable(app(installed: false)) != nil)
        // Replacing an installed app is the Updates page's, which checks
        // the new copy against the old.
        #expect(InstallRecordingModel.installable(app(installed: true)) == nil)
        #expect(InstallRecordingModel.installable(image([app(installed: false)]))?.kind == .application)
        #expect(InstallRecordingModel.installable(image([app(installed: false), app(installed: false)])) == nil)
        #expect(InstallRecordingModel.installable(package)?.kind == .package)
        #expect(InstallerSignature.Verdict.notarized.isTrusted)
        #expect(InstallerSignature.Verdict.notNotarized.isTrusted == false)
    }
}

private actor RecordingStub: BrimServiceProtocol {
    let result: InstallRecordingResult
    private(set) var kept: [InstallRecording] = []
    private(set) var cancelled = false

    init(result: InstallRecordingResult) {
        self.result = result
    }

    func beginInstallRecording() async throws -> Date {
        result.startedAt
    }

    func finishInstallRecording() async throws -> InstallRecordingResult {
        result
    }

    func keepInstallRecording(_ recording: InstallRecording) async throws {
        kept.append(recording)
    }

    func cancelInstallRecording() async {
        cancelled = true
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Unused.call
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Unused.call
    }

    func explain(planId _: UUID) async throws -> String {
        throw Unused.call
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Unused.call
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Unused.call
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Unused.call
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Unused.call
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }

    private enum Unused: Error { case call }
}
