import BrimCore
@testable import BrimUI
import XCTest

/// An app's page groups what it left by what removing it costs.
final class FootprintLossTests: XCTestCase {
    private func item(_ path: String) -> FootprintItem {
        FootprintItem(
            evidence: Evidence(url: URL(fileURLWithPath: path), tier: .A, mechanism: "test", humanSentence: ""),
            sizeBytes: 1, capability: .ok
        )
    }

    func testSettingsAndDataAreToldApartFromWhatRebuildsItself() {
        // The distinction a person acts on: preferences are their choices,
        // a cache comes back on its own.
        XCTAssertEqual(FootprintLoss.of(item("/Applications/Figma.app")), .app)
        XCTAssertEqual(FootprintLoss.of(item("/Users/me/Library/Preferences/com.figma.Desktop.plist")), .settings)
        XCTAssertEqual(FootprintLoss.of(item("/Users/me/Library/Application Support/Figma")), .data)
        XCTAssertEqual(FootprintLoss.of(item("/Users/me/Library/Caches/com.figma.Desktop")), .rebuilds)
        XCTAssertEqual(FootprintLoss.of(item("/Library/LaunchAgents/com.figma.agent.plist")), .background)
    }
}
