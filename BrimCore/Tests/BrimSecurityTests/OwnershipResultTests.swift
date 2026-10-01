import BrimCore
import BrimProtocol
import BrimScan
@testable import BrimService
import Darwin
import Foundation
import Testing

struct OwnershipResultTests {
    @Test func survivingCopyRetainsSharedPathsInTheResult() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        _ = try fixture.bundle("Users/tester/Applications/Editor Beta.app")
        let preferences = try fixture.file("Users/tester/Library/Preferences/org.example.editor.plist")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let plan = try await fixture.service().plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(plan.steps.contains { $0.target == preferences.path } == false)
        try FileManager.default.removeItem(at: selected)
        let report = RemovalReport.build(
            plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
            privacyResetFailed: false, survivingExtensions: nil
        )
        let protected = try #require(report.protectedItems.first { $0.target == preferences.path })
        #expect(protected.reason.contains("Shared with Editor Beta"))
        #expect(protected.presence == .present)
        #expect(report.leftUnticked.isEmpty)
        #expect(report.keptByMacOS.isEmpty)
    }

    @Test func aDistinctHostComponentProtectsSharedStateAndPrivacy() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        _ = try fixture.bundle("Applications/Host.app", id: "org.example.host")
        _ = try fixture.bundle("Applications/Host.app/Contents/Helpers/Embedded Editor.app")
        let preferences = try fixture.file("Users/tester/Library/Preferences/org.example.editor.plist")
        let support = try fixture.file("Users/tester/Library/Application Support/Editor/state.bin")
            .deletingLastPathComponent()
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let plan = try await fixture.service().plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(plan.steps.contains { $0.target == preferences.path || $0.target == support.path } == false)
        #expect(plan.steps.contains { $0.kind == .resetPrivacyGrants } == false)
        for target in [preferences.path, support.path] {
            let exclusion = try #require(plan.excludedItems.first { $0.target == target })
            #expect(exclusion.canBeTickedByHand == false)
            #expect(exclusion.reason.contains("Embedded Editor"))
        }
    }

    @Test func aSelectedEmbeddedComponentDoesNotBecomeItsOwnSurvivor() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let host = try fixture.bundle("Applications/Host.app", id: "org.example.host")
        let selected = try fixture.bundle("Applications/Host.app/Contents/Helpers/Editor.app")
        let preferences = try fixture.file("Users/tester/Library/Preferences/org.example.editor.plist")
        let support = try fixture.file("Users/tester/Library/Application Support/Editor/state.bin")
            .deletingLastPathComponent()
        let container = try fixture.file("Users/tester/Library/Containers/org.example.editor/Data/settings")
            .deletingLastPathComponent().deletingLastPathComponent()
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let plan = try await fixture.service().plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.steps.contains { $0.target == host.path } == false)
        for target in [selected.path, preferences.path, support.path, container.path] {
            #expect(plan.steps.contains { $0.target == target })
        }
        #expect(plan.steps.contains { $0.kind == .resetPrivacyGrants })
    }

    @Test func protectedPathObservationSeparatesMissingAndUncertainTargets() throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let present = try fixture.file("Present")
        let missing = fixture.root.rootURL.appendingPathComponent("Missing")
        let loop = fixture.root.rootURL.appendingPathComponent("Loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        let uncertain = loop.appendingPathComponent("Data")
        let unticked = try fixture.file("Unticked")
        let plan = Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
            intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Fixture")),
            steps: [], excludedItems: [
                ExcludedItem(target: present.path, reason: "Shared owner", canBeTickedByHand: false),
                ExcludedItem(target: missing.path, reason: "Shared owner", canBeTickedByHand: false),
                ExcludedItem(target: uncertain.path, reason: "Protected", canBeTickedByHand: false),
                ExcludedItem(target: unticked.path, reason: "Optional", canBeTickedByHand: true),
                ExcludedItem(target: "org.example.registration", reason: "Shared", canBeTickedByHand: false)
            ], expectedTotalBytes: 0
        )
        let report = RemovalReport.build(
            plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
            privacyResetFailed: false, survivingExtensions: nil
        )
        #expect(Set(report.protectedItems.map(\.target)) == [present.path, uncertain.path])
        #expect(report.protectedItems.first { $0.target == present.path }?.presence == .present)
        #expect(report.protectedItems.first { $0.target == uncertain.path }?.presence == .unknown)
        #expect(report.leftUnticked == [unticked.path])
    }

    @Test func olderReportsDecodeWithoutProtectedItems() throws {
        let report = RemovalReport(
            checkedGone: 1, registrationsChecked: [], declaredNone: [], keptByMacOS: [], stillThere: 0,
            protectedItems: [.init(target: "/Library/Shared", reason: "Shared", presence: .unknown)]
        )
        let encoded = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(RemovalReport.self, from: encoded) == report)
        var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "protectedItems")
        let older = try JSONDecoder().decode(RemovalReport.self,
                                             from: JSONSerialization.data(withJSONObject: fields))
        #expect(older.protectedItems.isEmpty)
    }

    @Test func onePresentApplicationProtectsAMultiAppCask() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let present = try fixture.bundle("Applications/Editor.app")
        let missing = fixture.root.rootURL.appendingPathComponent("Applications/Tools.app")
        try fixture.cask("editor-suite", applications: [present, missing])
        let service = fixture.service()
        #expect(await service.orphanedCaskNames().isEmpty)
        try FileManager.default.removeItem(at: present)
        #expect(await service.orphanedCaskNames() == ["editor-suite"])
    }

    @Test func oneUncertainApplicationProtectsAMultiAppCask() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let missing = fixture.root.rootURL.appendingPathComponent("Applications/Editor.app")
        let loop = fixture.root.rootURL.appendingPathComponent("Loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        let uncertain = loop.appendingPathComponent("Tools.app")
        var information = stat()
        #expect(lstat(uncertain.path, &information) == -1)
        #expect(errno == ELOOP)
        try fixture.cask("editor-suite", applications: [missing, uncertain])
        #expect(await fixture.service().orphanedCaskNames().isEmpty)
    }
}

extension OwnershipResultTests {
    @Test(arguments: [false, true])
    func malformedInstalledClaimantsKeepAutomaticSelectionIncomplete(invalidMetadata: Bool) async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        let unknown = fixture.root.url(for: .applications).appendingPathComponent("Unknown.app")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        if invalidMetadata {
            let metadata = unknown.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("invalid metadata".utf8).write(to: metadata)
        }
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let service = fixture.service()
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        #expect(plan.steps.isEmpty)
        let gaps = plan.scanCompleteness?.unreadable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(gaps?.contains(unknown.resolvingSymlinksInPath().path) == true)
        let selectedPath = selected.resolvingSymlinksInPath().path
        let row = try #require(plan.excludedItems.first {
            URL(fileURLWithPath: $0.target).resolvingSymlinksInPath().path == selectedPath
        })
        #expect(row.canBeTickedByHand == true)
        let manual = try await service.plan(intent: intent.tickingByHand([row.target]))
        #expect(manual.steps.contains {
            $0.kind == .trashPath && URL(fileURLWithPath: $0.target).resolvingSymlinksInPath().path == selectedPath
        })
        #expect(manual.scanCompleteness?.isComplete == false)
    }

    @Test func sharedPermissionsRemainVisibleWithoutExternalDataPaths() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        let copy = try fixture.bundle("Users/tester/Applications/Editor Beta.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let plan = try await fixture.service().plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        let copies = try #require(plan.survivingCopies)
        #expect(copies.count == 1)
        let protectingPath = try #require(copies.first?.bundlePath)
        // Foundation can retain /var in a constructed URL and return /private/var
        // from enumeration. Compare the actual filesystem locations.
        #expect(try canonicalPath(protectingPath) == canonicalPath(copy.path))
        #expect(plan.steps.contains { $0.kind == .resetPrivacyGrants } == false)
        let report = RemovalReport.build(
            plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
            privacyResetFailed: false, survivingExtensions: nil
        )
        let protection = try #require(report.sharedIdentityProtection)
        #expect(protection.identifier == "org.example.editor")
        #expect(protection.installations == copies)
        #expect(report.protectedItems.isEmpty)
        #expect(report.keptByMacOS.isEmpty)
        #expect(try JSONDecoder().decode(RemovalReport.self, from: JSONEncoder().encode(report)) == report)
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        older.removeValue(forKey: "survivingCopies")
        let originalFormat = try JSONDecoder().decode(
            Plan.self, from: JSONSerialization.data(withJSONObject: older)
        )
        #expect(originalFormat.survivingCopies == nil)
        #expect(try plan.contentHash() != originalFormat.contentHash())
        var oldReport = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        oldReport.removeValue(forKey: "sharedIdentityProtection")
        let decodedOldReport = try JSONDecoder().decode(
            RemovalReport.self, from: JSONSerialization.data(withJSONObject: oldReport)
        )
        #expect(decodedOldReport.sharedIdentityProtection == nil)
    }

    @Test func changingOnlyTheProtectingCopyRequiresNewReview() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        let copy = try fixture.bundle("Users/tester/Applications/Editor Beta.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let service = fixture.service()
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        let approval = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await service.grantApproval(for: approval)
        let preview = copy.deletingLastPathComponent().appendingPathComponent("Editor Preview.app")
        try FileManager.default.moveItem(at: copy, to: preview)
        let current = try await service.plan(intent: intent)
        #expect(current.steps == plan.steps)
        #expect(current.survivingCopies != plan.survivingCopies)
        await #expect(throws: BrimService.ApplyError.self) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
    }

    @Test(arguments: [false, true])
    func unresolvedAppArtifactsProtectTheWholeCask(nonSymbolic: Bool) async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let missing = fixture.root.rootURL.appendingPathComponent("Applications/Editor.app")
        let other = fixture.root.rootURL.appendingPathComponent("Applications/Tools.app")
        try fixture.cask("editor-suite", applications: [missing, other])
        let unresolved = fixture.caskDirectory("editor-suite").appendingPathComponent("1.0/Tools.app")
        try FileManager.default.removeItem(at: unresolved)
        if nonSymbolic {
            try Data("not an app link".utf8).write(to: unresolved)
        }
        let inventory = await BrimService.homebrewInventory(in: fixture.root)
        #expect(inventory.completeness.unreadable.contains(unresolved.path))
        #expect(inventory.installations.map(\.applicationPath) == [missing.path])
        #expect(await fixture.service().orphanedCaskNames().isEmpty)
    }

    @Test func anUnrelatedDamagedReceiptDoesNotHideProvenSelectedOwnership() async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        let other = try fixture.bundle("Applications/Other.app", id: "org.example.other")
        try fixture.cask("editor", applications: [selected])
        try fixture.cask("other", applications: [other])
        let receipt = fixture.caskDirectory("other").appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        try Data("malformed".utf8).write(to: receipt)
        let inventory = await BrimService.homebrewInventory(in: fixture.root)
        #expect(inventory.completeness.unreadable.contains(receipt.path))
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let service = fixture.service()
        let plan = try await service.plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.homebrewInstallation?.token == "editor")
        #expect(plan.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(plan.scanCompleteness == nil)
        let result = try await service.verify(planId: plan.planId)
        #expect(result.packageRecord?.state == .present)
    }

    @Test(arguments: [false, true])
    func unresolvedPotentialOwnersRequireManualSelection(knownOwner: Bool) async throws {
        let fixture = try OwnershipResultFixture()
        defer { fixture.remove() }
        let selected = try fixture.bundle("Applications/Editor.app")
        if knownOwner {
            try fixture.cask("editor", applications: [selected])
        }
        try fixture.cask("unknown", applications: [selected])
        let receipt = fixture.caskDirectory("unknown").appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        try Data("malformed".utf8).write(to: receipt)
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let service = fixture.service()
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        #expect(plan.homebrewInstallation == nil)
        #expect(plan.scanCompleteness?.unreadable.contains(receipt.path) == true)
        #expect(plan.steps.isEmpty)
        let manual = try await service.plan(intent: intent.tickingByHand([selected.path]))
        #expect(manual.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(manual.scanCompleteness?.unreadable.contains(receipt.path) == true)
        let report = RemovalReport.build(
            plan: manual, remaining: [], recorded: [:], staleRegistrations: 0,
            privacyResetFailed: false, survivingExtensions: nil
        )
        #expect(report.scanCompleteness?.unreadable.contains(receipt.path) == true)
    }
}

private struct OwnershipResultFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("brim-owner-result-\(UUID().uuidString)")
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: base.appendingPathComponent("Root"), userName: "tester")
    }

    init() throws {
        try FileManager.default.createDirectory(at: root.rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func service() -> BrimService {
        BrimService(root: root, brimAppURL: base.appendingPathComponent("Brim.app"),
                    planStoreDirectory: base.appendingPathComponent("Plans"),
                    journalStoreDirectory: base.appendingPathComponent("Journals"))
    }

    func file(_ relative: String) throws -> URL {
        let target = root.rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("settings".utf8).write(to: target)
        return target
    }

    func bundle(_ relative: String, id: String = "org.example.editor") throws -> URL {
        let target = root.rootURL.appendingPathComponent(relative)
        let metadata = target.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: metadata)
        return target
    }

    func caskDirectory(_ token: String) -> URL {
        root.rootURL.appendingPathComponent("opt/homebrew/Caskroom/" + token)
    }

    func cask(_ token: String, applications: [URL]) throws {
        let directory = caskDirectory(token)
        let receipt = directory.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let artifacts = applications.map { ["app": [$0.lastPathComponent]] }
        try JSONSerialization.data(withJSONObject: ["source": ["version": "1.0"], "uninstall_artifacts": artifacts])
            .write(to: receipt)
        let version = directory.appendingPathComponent("1.0")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        for application in applications {
            try FileManager.default.createSymbolicLink(
                at: version.appendingPathComponent(application.lastPathComponent),
                withDestinationURL: application
            )
        }
    }
}

private func canonicalPath(_ path: String) throws -> String {
    let resolved = try #require(realpath(path, nil))
    defer { free(resolved) }
    return String(cString: resolved)
}
