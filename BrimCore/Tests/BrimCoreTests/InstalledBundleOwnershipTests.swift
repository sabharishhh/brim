@testable import BrimCore
import Foundation
import Testing

struct InstalledBundleOwnershipTests {
    @Test func externalComponentGroupClaimsStayProtectedDuringAnIncompleteSearch() {
        let component = IdentitySurface.Component(
            path: "/Users/tester/Tools/Worker.app", bundleIdentifier: "org.example.worker", name: "Worker",
            bundleName: nil, teamIdentifier: nil, groups: ["group.org.example.shared"],
            urlSchemes: [], exportedTypes: []
        )
        let surface = IdentitySurface(bundlePath: component.path, components: [component])
        let application = Identity(bundleID: "org.example.worker", name: "Worker", bundlePath: component.path,
                                   identitySurface: surface)
        let claims = TierSVetoEngine.mergingGroupClaims(
            (owners: ["group.org.example.other": "Other"], complete: true),
            applications: [application], complete: false
        )
        #expect(claims.owners["group.org.example.shared"] == "Worker")
        #expect(claims.owners["group.org.example.other"] == "Other")
        #expect(!claims.complete)
    }

    @Test func failedLookupKeepsKnownCopiesAndReportsItsGap() throws {
        let fixture = try InstalledBundleOwnershipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let app = try fixture.bundle("Custom/Editor.app", identifier: "org.example.editor")
        let inventory = InstalledBundleInventory.read(
            in: fixture.root, including: ["org.example.editor"], knownLocations: [app],
            lookup: { _ in throw CocoaError(.fileReadNoPermission) }
        )
        #expect(inventory.bundles == [app])
        #expect(inventory.completeness.unreadable.contains("Launch Services: org.example.editor"))
    }

    @Test func lookupFailureRemovesAutomaticSelectionWithoutInventingACopy() async throws {
        let fixture = try InstalledBundleOwnershipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let target = fixture.folder.appendingPathComponent("Support")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: target, tier: .B, mechanism: "fixture", humanSentence: "Identifier match"),
            sizeBytes: 0, capability: .ok
        ), selection: .selected, costOfError: .medium)
        let result = await TierSVetoEngine(root: fixture.root, lookup: { _ in
            throw CocoaError(.fileReadNoPermission)
        }).applyVeto(to: EvaluatedFootprint(
            identity: Identity(bundleID: "org.example.editor", name: "Editor"), items: [item]
        ))
        #expect(!result.completeness.isComplete)
        #expect(result.items.first?.selection == .unselected)
        #expect(result.survivingCopies.isEmpty)
        #expect(result.protectedComponentIdentifiers.isEmpty)
    }

    @Test func customCopyProtectsAHelperIdentifierDespiteCaseDifferences() async throws {
        let fixture = try InstalledBundleOwnershipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let selected = try fixture.bundle("Applications/Editor.app", identifier: "org.example.editor")
        let copy = try fixture.bundle("Custom/Worker.app", identifier: "ORG.EXAMPLE.WORKER")
        let component = IdentitySurface.Component(
            path: selected.appendingPathComponent("Contents/XPCServices/Worker.xpc").path,
            bundleIdentifier: "org.example.worker", name: "Worker", bundleName: nil,
            teamIdentifier: nil, groups: [], urlSchemes: [], exportedTypes: []
        )
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: selected.path,
                                identitySurface: IdentitySurface(bundlePath: selected.path, components: [component]))
        let result = await TierSVetoEngine(root: fixture.root, lookup: { identifier in
            identifier == "org.example.worker" ? [copy] : []
        }).applyVeto(to: EvaluatedFootprint(identity: identity, items: []))
        #expect(result.protectedComponentIdentifiers.contains("org.example.worker"))
        #expect(result.survivingCopies.isEmpty)
    }
}

private struct InstalledBundleOwnershipFixture {
    let folder: URL
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: folder, userName: "tester")
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func bundle(_ relative: String, identifier: String) throws -> URL {
        let app = folder.appendingPathComponent(relative)
        let metadata = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: metadata)
        return app
    }
}
