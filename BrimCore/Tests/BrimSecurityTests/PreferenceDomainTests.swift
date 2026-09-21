import XCTest
import BrimOps

/// Preference domains, and the daemon that writes them back.
final class PreferenceDomainTests: XCTestCase {

    func testAnOrdinaryPreferencesFileNamesItsDomain() {
        XCTAssertEqual(
            PreferenceDomains.domain(
                forPlistAt: "/Users/x/Library/Preferences/com.example.app.plist"
            ),
            "com.example.app"
        )
    }

    func testAByHostFileStripsTheHardwareIdentifier() {
        // The domain is the part before the UUID; leaving it on would ask
        // cfprefsd about a domain that does not exist.
        XCTAssertEqual(
            PreferenceDomains.domain(
                forPlistAt: "/Users/x/Library/Preferences/ByHost/"
                          + "com.example.app.00000000-0000-1000-8000-0123456789AB.plist"
            ),
            "com.example.app"
        )
    }

    func testSomethingThatIsNotAPreferencesFileHasNoDomain() {
        XCTAssertNil(PreferenceDomains.domain(forPlistAt: "/Users/x/Library/Caches/thing.plist"))
        XCTAssertNil(PreferenceDomains.domain(forPlistAt: "/Library/LaunchAgents/com.x.plist"))
        XCTAssertNil(PreferenceDomains.domain(forPlistAt: "/Users/x/Library/Preferences/notes.txt"))
    }

    func testTheGlobalDomainIsNeverTouched() {
        // Clearing .GlobalPreferences resets system-wide settings that
        // belong to no application at all.
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain(".GlobalPreferences"))
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain("Apple.Global.Domain"))
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain("kCFPreferencesAnyApplication"))
        XCTAssertFalse(PreferenceDomains.forget(".GlobalPreferences"))
        XCTAssertTrue(PreferenceDomains.isPlausibleDomain("com.example.app"))
    }

    func testNothingWithoutADotIsADomain() {
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain("notadomain"))
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain("/etc/passwd"))
        XCTAssertFalse(PreferenceDomains.isPlausibleDomain(""))
    }
}
