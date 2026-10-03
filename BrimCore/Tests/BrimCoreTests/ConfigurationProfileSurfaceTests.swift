import BrimCore
import BrimScan
import Foundation
import Testing

struct ConfigurationProfileSurfaceTests {
    private let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/tmp/brim-profile-fixture"))

    private func profileData(
        clients: [[String: String]], format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        try profileData(items: [["PayloadType": "com.apple.TCC.configuration-profile-policy",
                                 "Services": ["SystemPolicyAllFiles": clients]]], format: format)
    }

    private func profileData(
        items: [[String: Any]], format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["tester": [[
            "ProfileIdentifier": "org.example.policy", "ProfileUUID": "policy-uuid",
            "ProfileDisplayName": "Shared policy",
            "ProfileItems": items
        ]]], format: format, options: 0)
    }

    @Test func sharedProfileReferencesAreReportedWithoutGrantingRemovalAuthority() async throws {
        let data = try profileData(clients: [
            ["IdentifierType": "bundleID", "Identifier": "org.example.target"],
            ["IdentifierType": "bundleID", "Identifier": "org.example.sentinel"],
            ["IdentifierType": "path", "Identifier": "/Applications/Target.app"]
        ])
        let surface = ConfigurationProfileSurface(read: { data })
        let snapshot = await surface.snapshot(in: root)
        #expect(snapshot.registrations.count == 3)
        #expect(Set(snapshot.registrations.compactMap(\.owningBundleID))
            == ["org.example.target", "org.example.sentinel"])
        #expect(Set(snapshot.registrations.map(\.id)).count == 3)
        #expect(snapshot.registrations.first { $0.programPath == "/Applications/Target.app" }?.owningBundleID == nil)
        #expect(snapshot.registrations.allSatisfy { $0.isReportOnly && !$0.isActionable })
        #expect(!snapshot.coverage.available)
        let report = await CapabilitySearchScanner(surfaces: [surface]).scan(
            identity: Identity(bundleID: "org.example.target", name: "Target"),
            in: root, completeness: .complete
        )
        let check = try #require(report?.checks.first { $0.capability == .configurationProfile })
        #expect(check.registrations.count == 1)
        #expect(check.followUp == .deviceManagementSettings)
        #expect(check.removalTier == .detectableOnly)
    }

    @Test func emptyUserListingDoesNotProveDevicePolicyAbsent() async throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["tester": []], format: .xml, options: 0)
        let snapshot = await ConfigurationProfileSurface(read: { data }).snapshot(in: root)
        #expect(snapshot.registrations.isEmpty)
        #expect(!snapshot.coverage.available)
        #expect(snapshot.coverage.limitation?.contains("Device-level") == true)
    }

    @Test func privacyClientsAndAppleEventReceiversKeepTheirDeclaredIdentityType() async throws {
        let data = try profileData(items: [[
            "PayloadType": "com.apple.TCC.configuration-profile-policy",
            "PayloadContent": ["Services": [
                "AppleEvents": [["IdentifierType": "bundleID", "Identifier": "org.example.sender",
                                 "AEReceiverIdentifierType": "path",
                                 "AEReceiverIdentifier": "/opt/helper/bin/receiver"]],
                "SystemPolicyAllFiles": [["IdentifierType": "path",
                                          "Identifier": "/Applications/Target.app/Contents/MacOS/helper",
                                          "AEReceiverIdentifierType": "bundleID",
                                          "AEReceiverIdentifier": "org.example.invalidReceiver"]]
            ]]
        ]])
        let snapshot = await ConfigurationProfileSurface(read: { data }).snapshot(in: root)
        #expect(Set(snapshot.registrations.compactMap(\.owningBundleID)) == ["org.example.sender"])
        #expect(Set(snapshot.registrations.compactMap(\.programPath))
            == ["/opt/helper/bin/receiver", "/Applications/Target.app/Contents/MacOS/helper"])
        #expect(snapshot.registrations.allSatisfy { $0.isReportOnly && !$0.isActionable })
        #expect(snapshot.registrations.allSatisfy { $0.targetPresence != .present && $0.targetPresence != .absent })
    }

    @Test func exactExtensionAndLoginRulesDoNotAttributeTeamOrPrefixPolicies() async throws {
        let data = try profileData(items: [["PayloadType": "Configuration", "PayloadContent": [
            ["PayloadType": "com.apple.system-extension-policy",
             "AllowedSystemExtensions": ["TEAMEXAMPLE": ["org.example.allowed"]],
             "RemovableSystemExtensions": ["TEAMEXAMPLE": ["org.example.removable"]],
             "NonRemovableSystemExtensions": ["TEAMEXAMPLE": ["org.example.fixed"]],
             "NonRemovableFromUISystemExtensions": ["TEAMEXAMPLE": ["org.example.hidden"]],
             "AllowedSystemExtensionTypes": ["TEAMEXAMPLE": ["NetworkExtension"]],
             "AllowedTeamIdentifiers": ["TEAMEXAMPLE"]],
            ["PayloadType": "com.apple.servicemanagement", "Rules": [
                ["RuleType": "BundleIdentifier", "RuleValue": "org.example.login"],
                ["RuleType": "BundleIdentifierPrefix", "RuleValue": "org.example.prefix"],
                ["RuleType": "TeamIdentifier", "RuleValue": "TEAMEXAMPLE"],
                ["RuleType": "Label", "RuleValue": "org.example.job"],
                ["RuleType": "LabelPrefix", "RuleValue": "org.example.jobs"]
            ]],
            ["PayloadType": "org.example.unsupported", "Rules": [
                ["RuleType": "BundleIdentifier", "RuleValue": "org.example.unrelated"]
            ]]
        ]]])
        let snapshot = await ConfigurationProfileSurface(read: { data }).snapshot(in: root)
        #expect(Set(snapshot.registrations.compactMap(\.owningBundleID))
            == ["org.example.allowed", "org.example.removable", "org.example.fixed",
                "org.example.hidden", "org.example.login"])
        #expect(snapshot.readerVersion == 2)
        #expect(!snapshot.coverage.available)
    }

    @Test func binaryPathReferenceMatchesOnlyTheContainingReviewedBundle() async throws {
        let data = try profileData(clients: [
            ["IdentifierType": "path", "Identifier": "/Applications/Target.app/Contents/MacOS/helper"],
            ["IdentifierType": "path", "Identifier": "/Applications/Target.app.extra/Contents/MacOS/helper"],
            ["IdentifierType": "path", "Identifier": "relative/bin/helper"],
            ["IdentifierType": "path", "Identifier": "/Applications/Target.app/../Other.app/helper"],
            ["IdentifierType": "bundleID", "Identifier": "org.example.*"],
            ["IdentifierType": "bundleID", "Identifier": "org.example.invalid\0"]
        ], format: .binary)
        let report = await CapabilitySearchScanner(surfaces: [ConfigurationProfileSurface(read: { data })]).scan(
            identity: Identity(bundleID: "org.example.target", name: "Target", bundlePath: "/Applications/Target.app"),
            in: root, completeness: .complete
        )
        let check = try #require(report?.checks.first { $0.capability == .configurationProfile })
        #expect(check.registrations.count == 1)
        #expect(check.registrations.first?.programPath == "/Applications/Target.app/Contents/MacOS/helper")
        #expect(check.followUp == .deviceManagementSettings)
    }

    @Test func failedAndMalformedReadsStayUnknown() async {
        for data in [nil, Data(), Data("unexpected output".utf8)] as [Data?] {
            let snapshot = await ConfigurationProfileSurface(read: { data }).snapshot(in: root)
            #expect(!snapshot.coverage.available)
            #expect(snapshot.registrations.isEmpty)
        }
    }
}
