import XCTest
import Foundation
@testable import BrimCore

final class FileSystemRootTests: XCTestCase {
    
    func testDomainResolution() {
        let fakeRoot = URL(fileURLWithPath: "/private/var/folders/xyz/temp")
        let fsRoot = FileSystemRoot(rootURL: fakeRoot, userName: "sabharish")
        
        let prefsURL = fsRoot.url(for: .userPreferences)
        
        // Assert it resolves UNDER the fixture root
        XCTAssertTrue(prefsURL.path.hasPrefix(fakeRoot.path), "URL should be bounded by the injected root")
        XCTAssertEqual(prefsURL.path, "/private/var/folders/xyz/temp/Users/sabharish/Library/Preferences")
        
        // Assert system domains
        let sysDaemons = fsRoot.url(for: .systemLaunchDaemons)
        XCTAssertEqual(sysDaemons.path, "/private/var/folders/xyz/temp/Library/LaunchDaemons")
    }
}
