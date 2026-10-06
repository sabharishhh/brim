import BrimCore
import BrimUI
import XCTest

final class FootprintSectionTests: XCTestCase {
    private func item(
        _ path: String, tier: EvidenceTier = .B, bytes: Int64 = 100,
        unreadable: Int = 0, measurement: ArtifactSize? = nil
    ) -> FootprintItem {
        FootprintItem(
            evidence: Evidence(url: URL(fileURLWithPath: path), tier: tier,
                               mechanism: "test", humanSentence: tier.shortLabel),
            sizeBytes: bytes, capability: .ok, unreadableEntries: unreadable, sizeMeasurement: measurement
        )
    }

    private func sections(_ items: [FootprintItem]) -> [FootprintSection] {
        FootprintSection.arrange(Footprint(identity: Identity(bundleID: "example", name: "Example"), items: items))
    }

    func testNavigationKeepsEveryKindIncludingUnmatchedLocations() {
        let result = sections([
            item("/tmp/unclassified"), item("/Library/LaunchAgents/example.plist"),
            item("/Users/me/Library/Caches/example"), item("/Applications/Example.app"),
            item("/Users/me/Library/Application Support/Example"),
            item("/Users/me/Library/Preferences/example.plist")
        ])
        XCTAssertEqual(result.map(\.loss), [.app, .settings, .data, .background, .rebuilds, .other])
        XCTAssertEqual(result.flatMap(\.locations).count, 6)
        XCTAssertEqual(sections([]), [])
    }

    func testRepeatedEvidenceNamesOneLocationAndPreservesSharedRecord() throws {
        // A navigation count must not count one path twice or hide its veto.
        let result = sections([
            item("/tmp/example", tier: .A), item("/tmp/./example", tier: .S)
        ])
        let location = try XCTUnwrap(result.first?.locations.first)
        XCTAssertEqual(result.first?.locations.count, 1)
        XCTAssertEqual(location.items.count, 2)
        XCTAssertEqual(location.items.first?.evidence.tier, .S)
        XCTAssertTrue(location.isShared)
        XCTAssertEqual(location.logicalBytes, 100)
    }

    func testDifferentSizeObservationsRemainUnknownRatherThanChoosingOne() throws {
        let location = try XCTUnwrap(sections([
            item("/tmp/example", bytes: 100), item("/tmp/example", bytes: 200)
        ]).first?.locations.first)
        XCTAssertNil(location.logicalBytes)
    }

    func testIncompleteMeasurementCannotLookLikeACompleteZero() throws {
        let incomplete = [
            item("/tmp/example", bytes: 0, unreadable: 1),
            item("/tmp/example", bytes: 0, measurement: .pending)
        ]
        for evidence in incomplete {
            let location = try XCTUnwrap(sections([evidence]).first?.locations.first)
            XCTAssertTrue(location.isPartial)
        }
    }

    func testStableOrderAndIdentityDoNotDependOnDiscoveryOrder() {
        let items = [item("/tmp/b", bytes: 100), item("/tmp/a", bytes: 100), item("/tmp/c", bytes: 200)]
        XCTAssertEqual(sections(items), sections(Array(items.reversed())))
        XCTAssertEqual(sections(items).first?.locations.map(\.id), ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    /// WhatsApp's Application Scripts folders were grouped as Other, and a
    /// folder named for an identifier ending in ".app" was grouped as the app.
    func testScriptsAndAutosavesAreDataAndDotConfigIsSettings() {
        let result = sections([
            item("/Users/me/Library/Application Scripts/net.whatsapp.WhatsApp"),
            item("/Users/me/Library/Containers/io.getpurge.app"),
            item("/Users/me/.config/example")
        ])
        XCTAssertEqual(result.map(\.loss), [.settings, .data])
        XCTAssertEqual(result.last?.locations.count, 2)
    }
}
