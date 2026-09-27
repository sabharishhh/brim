import XCTest
@testable import BrimPrivileged

/// What the root daemon refuses when asked to set aside a command link.
///
/// The daemon exists so that nine dead links in a root-owned
/// `/usr/local/bin` can go without the person being asked for anything.
/// Each case here is a way a caller could try to use that to remove
/// something alive: a path in the name, a link that still works, a real
/// file with a link's name, a destination the daemon cannot see.
final class PrivilegedLinkRemovalTests: XCTestCase {

    private var directory: URL!
    private var descriptor: Int32 = -1

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
    }

    override func tearDownWithError() throws {
        if descriptor >= 0 { close(descriptor) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent(name).path, withDestinationPath: destination
        )
    }

    private func refusal(_ name: String) -> PrivilegedLinkRemoval.Refusal? {
        do {
            _ = try PrivilegedLinkRemoval.deadDestination(parent: descriptor, name: name)
            return nil
        } catch let refusal as PrivilegedLinkRemoval.Refusal {
            return refusal
        } catch {
            return nil
        }
    }

    // MARK: - The interface cannot express a dangerous request

    func testAPathCannotBeSmuggledThroughTheName() {
        for attempt in ["../../etc/sudoers", "/etc/sudoers", "..", ".", "sub/tool", ".hidden", ""] {
            XCTAssertThrowsError(
                try PrivilegedLinkRemoval.target(domain: "usrLocalBin", name: attempt),
                "\(attempt) was not refused"
            )
        }
    }

    func testOnlyTheTwoCommandFoldersExist() {
        XCTAssertThrowsError(try PrivilegedLinkRemoval.target(domain: "usrBin", name: "ls"))
        XCTAssertThrowsError(try PrivilegedLinkRemoval.target(domain: "/usr/bin", name: "ls"))
        XCTAssertEqual(
            try PrivilegedLinkRemoval.target(domain: "usrLocalBin", name: "kubectl").path,
            "/usr/local/bin/kubectl"
        )
        XCTAssertEqual(
            Set(PrivilegedLinkRemoval.Domain.allCases.map(\.directory)),
            ["/usr/local/bin", "/usr/local/sbin"]
        )
    }

    // MARK: - Only a dead link is ever touched

    func testALinkIntoADeletedApplicationIsDead() throws {
        // The real case: Docker was removed and its commands were not.
        try link("kubectl", to: "/Applications/Docker-\(UUID().uuidString).app/Contents/Resources/bin/kubectl")
        XCTAssertNil(refusal("kubectl"))
    }

    func testARelativeLinkIsJudgedFromItsOwnFolder() throws {
        // `python3t -> ../../../Library/Frameworks/...` is how the Python
        // installer writes them. Relative to the folder, not to wherever
        // the daemon happens to be running.
        try Data().write(to: directory.appendingPathComponent("real-tool"))
        try link("alive", to: "real-tool")
        try link("dead", to: "missing-tool")

        XCTAssertEqual(refusal("alive"), .stillPointsAtSomething("real-tool"))
        XCTAssertNil(refusal("dead"))
    }

    func testALinkThatStillWorksIsNeverTouched() throws {
        try link("sh", to: "/bin/sh")
        XCTAssertEqual(refusal("sh"), .stillPointsAtSomething("/bin/sh"))
    }

    func testARealFileIsNotALinkWhateverItIsCalled() throws {
        try Data("#!/bin/sh\n".utf8).write(to: directory.appendingPathComponent("tool"))
        XCTAssertEqual(refusal("tool"), .notALink)
    }

    func testALoopIsNotProofOfAnything() throws {
        try link("a", to: "b")
        try link("b", to: "a")
        XCTAssertEqual(refusal("a"), .stillPointsAtSomething("b"))
    }

    func testAChainThatEndsInSomethingStillWorks() throws {
        try Data().write(to: directory.appendingPathComponent("end"))
        try link("middle", to: "end")
        try link("start", to: "middle")
        XCTAssertEqual(refusal("start"), .stillPointsAtSomething("middle"))
    }

    func testSomethingMissingIsNotThere() {
        XCTAssertEqual(refusal("never-existed"), .notThere)
    }
}
