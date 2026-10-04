@testable import BrimCore
import BrimOps
@testable import BrimScan
import Foundation
import Testing

/// The same bundle identifier can name two installations. Removing one
/// must not take the other installation's bundle or shared state with it.
struct SurvivingCopyTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var root: FileSystemRoot {
            FileSystemRoot(rootURL: directory, userName: "tester")
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func bundle(_ relative: String, id: String = "org.example.editor") throws -> URL {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": id, "CFBundleName": "Editor", "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }

        func item(_ url: URL, mechanism: String = "LocationInventorySource") -> EvaluatedItem {
            EvaluatedItem(footprintItem: FootprintItem(
                evidence: Evidence(url: url, tier: .A, mechanism: mechanism, humanSentence: "Fixture ownership"),
                sizeBytes: 1, capability: .ok
            ), selection: .selected, costOfError: .medium)
        }
    }

    @Test func selectedBundleDoesNotExpandToAnotherCopy() async throws {
        let fixture = Fixture()
        let selected = try fixture.bundle("Applications/Editor.app")
        _ = try fixture.bundle("Users/tester/Applications/Editor.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let evidence = try await AppBundleSource().evidence(for: identity, in: fixture.root)
        #expect(evidence.map(\.url.path) == [selected.path])
    }

    @Test func survivingCopyVetoesSharedStateAndPrivacyReset() async throws {
        let fixture = Fixture()
        let selected = try fixture.bundle("Applications/Editor.app")
        let other = try fixture.bundle("Users/tester/Applications/Editor Beta.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let preferences = fixture.root.url(for: .userPreferences).appendingPathComponent("org.example.editor.plist")
        let support = fixture.root.url(for: .userApplicationSupport).appendingPathComponent("Editor")
        let footprint = EvaluatedFootprint(identity: identity, items: [
            fixture.item(selected, mechanism: "AppBundleSource"), fixture.item(preferences), fixture.item(support)
        ])
        let vetted = await TierSVetoEngine(root: fixture.root).applyVeto(to: footprint)
        #expect(vetted.items[0].selection == .selected)
        for item in vetted.items.dropFirst() {
            guard case let .excluded(reason) = item.selection else {
                Issue.record("Shared state remained removable: \(item.footprintItem.evidence.url)")
                continue
            }
            #expect(reason.contains(other.deletingPathExtension().lastPathComponent))
        }
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
            .tickingByHand([preferences.path, support.path])
        let plan = Planner().createPlan(from: vetted, intent: intent, engineVersion: "test")
        #expect(plan.steps.contains { $0.target == selected.path && $0.kind == .trashPath })
        #expect(!plan.steps.contains { $0.target == preferences.path || $0.target == support.path })
        #expect(!plan.steps.contains { $0.kind == .resetPrivacyGrants })
        #expect(plan.excludedItems.allSatisfy { $0.canBeTickedByHand != true })
    }

    @Test func embeddedComponentIsNotASurvivingCopy() async throws {
        let fixture = Fixture()
        let selected = try fixture.bundle("Applications/Editor.app")
        _ = try fixture.bundle("Applications/Editor.app/Contents/Library/LoginItems/Helper.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let preferences = fixture.root.url(for: .userPreferences).appendingPathComponent("org.example.editor.plist")
        let vetted = await TierSVetoEngine(root: fixture.root).applyVeto(to: EvaluatedFootprint(
            identity: identity, items: [fixture.item(selected), fixture.item(preferences)]
        ))
        #expect(vetted.items.allSatisfy { $0.selection == .selected })
        let plan = Planner().createPlan(from: vetted,
                                        intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                        engineVersion: "test")
        #expect(plan.steps.contains { $0.kind == .resetPrivacyGrants })
    }

    @Test func runningAnotherCopyDoesNotQuitOrBlockTheSelectedCopy() throws {
        let fixture = Fixture()
        let selected = try fixture.bundle("Applications/Editor.app")
        let other = try fixture.bundle("Users/tester/Applications/Editor.app")
        let running = [RunningApplications.Running(bundleIdentifier: "org.example.editor", name: "Editor",
                                                   bundlePath: other.path, isBackground: true)]
        #expect(RunningApplications.whatIsRunning(bundleID: "org.example.editor", bundlePath: selected.path,
                                                  among: running).isEmpty)
    }

    @Test func duplicateIdentifierProtectsPrivacyButNotAnotherPathsRegistration() async throws {
        let fixture = Fixture()
        let selected = try fixture.bundle("Applications/Editor.app")
        let other = try fixture.bundle("Users/tester/Applications/Editor Beta.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path)
        let otherIdentity = Identity(bundleID: "org.example.editor", name: "Editor Beta", bundlePath: other.path)
        let privacy = Registration(kind: .privacyGrant, identifier: "org.example.editor", label: "Privacy",
                                   owningBundleID: "org.example.editor", targetExists: true, evidence: "Fixture")
        let ownRecord = Registration(kind: .launchServices, identifier: "org.example.editor", label: "Editor",
                                     owningBundleID: "org.example.editor", programPath: selected.path,
                                     targetExists: true, evidence: "Fixture")
        let otherRecord = Registration(kind: .launchServices, identifier: "org.example.editor", label: "Editor Beta",
                                       owningBundleID: "org.example.editor", programPath: other.path,
                                       targetExists: true,
                                       evidence: "Fixture")
        let inventory = RegistrationInventory(surfaces: [Surface(entries: [privacy, ownRecord, otherRecord])])
        let owned = await inventory.owned(by: identity, bundleURL: selected, in: fixture.root,
                                          alsoClaimedBy: [(otherIdentity, other)])
        #expect(owned == [ownRecord])
        #expect(await inventory
            .alsoClaiming(privacy, besides: identity, among: [(otherIdentity, other)]) == [otherIdentity])
    }
}

private struct Surface: RegistrationSurface {
    let entries: [Registration]
    var kind: Registration.Kind {
        .privacyGrant
    }

    func registrations(in _: FileSystemRoot) async -> [Registration] {
        entries
    }

    func coverage(in _: FileSystemRoot) async -> RegistrationCoverage {
        .available(kind)
    }
}
