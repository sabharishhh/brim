import XCTest
@testable import BrimUI

/// The check for a newer Brim on GitHub. Brim 1.0 is not notarised and has
/// no updater, so this is the only way anyone running it hears of a fix.
@MainActor
final class BrimReleaseTests: XCTestCase {
    private func payload(_ tag: String, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/sabharishhh/brim/releases/tag/\#(tag)","draft":false,"prerelease":\#(prerelease)}"#.utf8)
    }

    private func check(_ current: String, answering data: Data?) -> BrimReleaseCheck {
        let defaults = UserDefaults(suiteName: "release-\(UUID().uuidString)")!
        return BrimReleaseCheck(current: current, defaults: defaults) { _ in
            guard let data else { throw URLError(.notConnectedToInternet) }
            return data
        }
    }

    func testANewerTagIsOfferedWithItsPage() async {
        let release = check("1.0", answering: payload("v1.0.1"))
        let answer = await release.check()
        XCTAssertEqual(release.available?.version, "1.0.1")
        XCTAssertEqual(answer, .newer(release.available!))
        XCTAssertEqual(release.available?.page.lastPathComponent, "v1.0.1")
    }

    /// 1.0 and 1.0.0 are one version, and the tag carries a v.
    func testTheSameVersionIsNotOffered() async {
        let release = check("1.0", answering: payload("v1.0.0"))
        let answer = await release.check()
        XCTAssertNil(release.available)
        XCTAssertEqual(answer, .current("1.0"))
    }

    func testAPreReleaseIsNotOffered() async {
        let release = check("1.0", answering: payload("v1.1.0", prerelease: true))
        _ = await release.check()
        XCTAssertNil(release.available)
    }

    /// Before the first release GitHub answers 404, which means there is
    /// nothing newer, not that GitHub could not be reached.
    func testNoReleaseYetIsTheLatest() async {
        let defaults = UserDefaults(suiteName: "release-\(UUID().uuidString)")!
        let release = BrimReleaseCheck(current: "1.0", defaults: defaults) { _ in nil }
        let answer = await release.check()
        XCTAssertEqual(answer, .current("1.0"))
    }

    /// No connection says nothing on launch.
    func testUnreachableIsSilentAndChecksAgainNextLaunch() async {
        let release = check("1.0", answering: nil)
        let answer = await release.check()
        XCTAssertEqual(answer, .unreachable)
        XCTAssertNil(release.available)
    }

    func testTheLaunchCheckRunsAtMostOnceADay() async {
        let defaults = UserDefaults(suiteName: "release-\(UUID().uuidString)")!
        let calls = Counter()
        let release = BrimReleaseCheck(current: "1.0", defaults: defaults) { _ in
            await calls.bump()
            return Data(#"{"tag_name":"v1.0"}"#.utf8)
        }
        let now = Date()
        await release.checkIfDue(now: now)
        await release.checkIfDue(now: now.addingTimeInterval(3600))
        await release.checkIfDue(now: now.addingTimeInterval(25 * 3600))
        let count = await calls.value
        XCTAssertEqual(count, 2)
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
