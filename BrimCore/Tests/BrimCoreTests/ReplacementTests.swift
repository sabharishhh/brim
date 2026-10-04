@testable import BrimCore
import XCTest

/// "Replaced by" is said only on proof: a record of where the old app was,
/// an installed app with another identifier at exactly that path, and the
/// same developer's namespace. Every way it could be wrong has a case here.
final class ReplacementTests: XCTestCase {
    private let codex = Replacement.Installed(bundleID: "com.openai.codex", name: "ChatGPT",
                                              path: "/Applications/ChatGPT.app")

    func testTheSamePathAndDeveloperIsAReplacement() {
        let found = Replacement.find(removed: "com.openai.chat", formerPaths: ["/Applications/ChatGPT.app"],
                                     installed: [codex])
        XCTAssertEqual(found, Replacement(name: "ChatGPT", path: "/Applications/ChatGPT.app"))
    }

    /// The real case on the Mac this was written on: nothing records where
    /// com.openai.chat was, so nothing is claimed, whatever the names say.
    func testNoRecordOfWhereItWasMeansNoClaim() {
        XCTAssertNil(Replacement.find(removed: "com.openai.chat", formerPaths: [], installed: [codex]))
    }

    func testAnotherDeveloperAtTheSamePathIsNotAReplacement() {
        let other = Replacement.Installed(bundleID: "com.somebody.chatgpt", name: "ChatGPT",
                                          path: "/Applications/ChatGPT.app")
        XCTAssertNil(Replacement.find(removed: "com.openai.chat", formerPaths: ["/Applications/ChatGPT.app"],
                                      installed: [other]))
    }

    func testTheSameDeveloperSomewhereElseIsNotAReplacement() {
        XCTAssertNil(Replacement.find(removed: "com.openai.chat", formerPaths: ["/Applications/Old ChatGPT.app"],
                                      installed: [codex]))
    }

    func testAnOldIdentifierStillInstalledIsNotReplaced() {
        let old = Replacement.Installed(bundleID: "com.openai.chat", name: "ChatGPT Classic",
                                        path: "/Users/x/Applications/ChatGPT.app")
        XCTAssertNil(Replacement.find(removed: "com.openai.chat", formerPaths: ["/Applications/ChatGPT.app"],
                                      installed: [codex, old]))
    }

    func testTheSameIdentifierAtThePathIsNotAReplacement() {
        let same = Replacement.Installed(
            bundleID: "COM.OPENAI.CHAT",
            name: "ChatGPT",
            path: "/Applications/ChatGPT.app"
        )
        XCTAssertNil(Replacement.find(removed: "com.openai.chat", formerPaths: ["/Applications/ChatGPT.app"],
                                      installed: [same]))
    }

    func testTwoCandidatesGiveNoAnswer() {
        let second = Replacement.Installed(bundleID: "com.openai.atlas", name: "Atlas", path: "/Applications/Atlas.app")
        XCTAssertNil(Replacement.find(removed: "com.openai.chat",
                                      formerPaths: ["/Applications/ChatGPT.app", "/Applications/Atlas.app"],
                                      installed: [codex, second]))
    }

    func testPathsCompareIgnoringCaseAndTrailingSlash() {
        XCTAssertNotNil(Replacement.find(removed: "com.openai.chat", formerPaths: ["/applications/chatgpt.app/"],
                                         installed: [codex]))
    }

    func testApplesAppsAreNeverClaimed() {
        let notes = Replacement.Installed(bundleID: "com.apple.Notes2", name: "Notes", path: "/Applications/Notes.app")
        XCTAssertNil(Replacement.find(removed: "com.apple.Notes", formerPaths: ["/Applications/Notes.app"],
                                      installed: [notes]))
    }

    func testTheDeveloperIsTheVendorOrTheAccountOnASharedHost() {
        XCTAssertEqual(Replacement.developer(of: "com.openai.chat"), "com.openai")
        XCTAssertEqual(Replacement.developer(of: "com.microsoft.teams2"), "com.microsoft")
        XCTAssertEqual(Replacement.developer(of: "jp.co.nikon.UninstallCenter"), "jp.co.nikon")
        XCTAssertEqual(Replacement.developer(of: "io.github.someone.app"), "io.github.someone")
        XCTAssertNil(Replacement.developer(of: "com.openai"), "nothing names a product")
        XCTAssertNil(Replacement.developer(of: "io.github.someone"))
    }

    /// A namespace is the developer's, not a shared root: two apps under
    /// `com.github` from different people are not one developer's.
    func testASharedRootNamespaceNeedsTheSameOwner() {
        let original = Replacement.Installed(
            bundleID: "com.github.someone.tool",
            name: "Tool",
            path: "/Applications/Tool.app"
        )
        XCTAssertNil(Replacement.find(removed: "com.github.other.tool", formerPaths: ["/Applications/Tool.app"],
                                      installed: [original]))
    }

    /// A group speaks for its items only when they agree.
    func testAGroupClaimsAReplacementOnlyWhenEveryItemAgrees() {
        let found = Replacement(name: "ChatGPT", path: "/Applications/ChatGPT.app")
        var original = Leftover(
            url: URL(fileURLWithPath: "/u/Library/Caches/com.openai.chat"),
            size: 1,
            category: .orphaned
        )
        var replacement = Leftover(url: URL(fileURLWithPath: "/u/Library/Preferences/com.openai.chat.plist"), size: 1,
                                   category: .orphaned)
        original.replacedBy = found
        XCTAssertNil(LeftoverGroup(displayName: "x", identifier: nil, items: [original, replacement], groupKey: "k")
            .replacedBy)
        replacement.replacedBy = found
        XCTAssertEqual(
            LeftoverGroup(displayName: "x", identifier: nil, items: [original, replacement], groupKey: "k").replacedBy,
            found
        )
    }
}
