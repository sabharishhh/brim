import XCTest
@testable import BrimCore

/// Nothing in Brim promises how long the battery will last.
///
/// Kept when the energy ledger went: a projection depends on what the
/// machine does next, which nobody knows, and a figure in minutes reads as
/// a promise. The first time it is wrong, every other number in the product
/// is suspect too.
final class BatteryLifeProjectionTests: XCTestCase {

    /// No string in the product projects future battery life in time
    /// units.
    ///
    /// A projection depends on what the machine does next, which nobody
    /// knows. A figure in minutes reads as a promise, and the first time
    /// it is wrong every other number in the product is suspect too.
    func testNothingPromisesHowLongTheBatteryWillLast() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()

        let forbidden = [
            "hours of battery", "minutes of battery", "battery life remaining",
            "hours remaining", "minutes remaining", "time remaining",
            "will last", "estimated battery",
        ]

        for directory in ["BrimCore/Sources", "Brim"] {
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil
            )
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                for phrase in forbidden {
                    XCTAssertFalse(
                        text.contains(phrase),
                        "\(file.lastPathComponent) projects battery life with \"\(phrase)\". "
                        + "Energy is stated as what was used, never as time left."
                    )
                }
            }
        }
    }
}
