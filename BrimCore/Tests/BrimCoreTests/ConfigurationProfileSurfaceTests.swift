import BrimCore
import BrimScan
import Foundation
import Testing

struct ConfigurationProfileSurfaceTests {
    private let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/tmp/brim-profile-fixture"))

    private func profileData(clients: [[String: String]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["tester": [[
            "ProfileIdentifier": "org.example.policy", "ProfileUUID": "policy-uuid",
            "ProfileDisplayName": "Shared policy",
            "ProfileItems": [["PayloadType": "com.apple.TCC.configuration-profile-policy",
                              "Services": ["SystemPolicyAllFiles": clients]]]
        ]]], format: .xml, options: 0)
    }

    @Test func sharedProfileReferencesAreReportedWithoutGrantingRemovalAuthority() async throws {
        let data = try profileData(clients: [
            ["IdentifierType": "bundleID", "Identifier": "org.example.target"],
            ["IdentifierType": "bundleID", "Identifier": "org.example.sentinel"],
            ["IdentifierType": "path", "Identifier": "/Applications/Target.app"]
        ])
        let surface = ConfigurationProfileSurface(read: { data })
        let snapshot = await surface.snapshot(in: root)
        #expect(snapshot.registrations.count == 2)
        #expect(Set(snapshot.registrations.compactMap(\.owningBundleID))
            == ["org.example.target", "org.example.sentinel"])
        #expect(Set(snapshot.registrations.map(\.id)).count == 2)
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

    @Test func failedAndMalformedReadsStayUnknown() async {
        for data in [nil, Data(), Data("unexpected output".utf8)] as [Data?] {
            let snapshot = await ConfigurationProfileSurface(read: { data }).snapshot(in: root)
            #expect(!snapshot.coverage.available)
            #expect(snapshot.registrations.isEmpty)
        }
    }
}
