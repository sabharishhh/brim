import XCTest
import BrimCore
@testable import BrimUI

/// Dropping an application on the window selects it.
@MainActor
final class DropSelectionTests: XCTestCase {

    private func app(_ name: String, _ bundleID: String) -> InstalledApplication {
        InstalledApplication(
            identity: Identity(bundleID: bundleID, name: name),
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleSizeBytes: 1_000, isSystemProtected: false
        )
    }

    private func model(_ applications: [InstalledApplication]) -> ApplicationsModel {
        let model = ApplicationsModel()
        model.acceptForTesting(applications)
        return model
    }

    func testDroppingAnApplicationSelectsIt() {
        let model = model([app("Figma", "com.figma.Desktop"), app("IINA", "com.colliderli.iina")])

        XCTAssertTrue(
            model.selectApplication(at: URL(fileURLWithPath: "/Applications/IINA.app"))
        )
        XCTAssertEqual(model.selected?.name, "IINA")
    }

    func testDroppingSomethingInsideABundleSelectsTheApplication() {
        // Dragging from inside a bundle, or dropping an alias that
        // resolves into one, should land on the same row.
        let model = model([app("IINA", "com.colliderli.iina")])

        XCTAssertTrue(model.selectApplication(
            at: URL(fileURLWithPath: "/Applications/IINA.app/Contents/MacOS/IINA")
        ))
        XCTAssertEqual(model.selected?.name, "IINA")
    }

    func testDroppingSomethingElseSaysSoRatherThanDoingNothing() {
        let model = model([app("IINA", "com.colliderli.iina")])
        XCTAssertFalse(
            model.selectApplication(at: URL(fileURLWithPath: "/Users/x/Documents/notes.txt"))
        )
        XCTAssertNil(model.selected)
    }

    func testASiblingPathIsNotAMatch() {
        // "/Applications/IINA.app" must not swallow "/Applications/IINA.app.backup".
        let model = model([app("IINA", "com.colliderli.iina")])
        XCTAssertFalse(
            model.selectApplication(at: URL(fileURLWithPath: "/Applications/IINA.app.backup"))
        )
    }

    func testAnActiveSearchIsClearedSoTheRowIsVisible() {
        // Selecting a row filtered out of the list looks like nothing
        // happened.
        let model = model([app("Figma", "com.figma.Desktop"), app("IINA", "com.colliderli.iina")])
        model.searchText = "Figma"

        XCTAssertTrue(model.selectApplication(at: URL(fileURLWithPath: "/Applications/IINA.app")))
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertTrue(model.visibleApplications.contains { $0.name == "IINA" })
    }
}
