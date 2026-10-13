@testable import BrimScan
import XCTest

/// What an unknown leftover is called when nothing records its owner.
final class LeftoverNamingTests: XCTestCase {
    /// Two scripts in /usr/local/bin were grouped as one row called "Sh".
    func testAFileExtensionIsNotAnOwnersName() {
        let bin = URL(fileURLWithPath: "/usr/local/bin")
        for name in ["update-container.sh", "uninstall-container.sh"] {
            XCTAssertEqual(LeftoversScanner.readableName(ownerID: name, url: bin.appendingPathComponent(name)), name)
        }
    }
}
