@testable import BrimPrivileged
import XCTest

/// Who is allowed to talk to whom. Brim's only connection is to its
/// temporary administrator process, and `TemporaryAdminChannel` checks both
/// ends against the requirements `BrimJobHelper` builds.
final class PeerAuthenticationTests: XCTestCase {
    // MARK: - The requirements

    func testTheRequirementNamesThisApplicationAndThisTeam() {
        let requirement = BrimJobHelper.clientRequirement()

        XCTAssertTrue(requirement.contains("identifier \"com.sabharishhh.brim\""), requirement)
        XCTAssertTrue(requirement.contains("9LY29YLFG2"), requirement)
        XCTAssertTrue(requirement.hasPrefix("anchor apple generic"),
                      "Without an anchor, any process can claim the identifier")
        XCTAssertFalse(requirement.contains("com.google.Brim"))
        XCTAssertFalse(requirement.contains("EQHXZ8M8AV"), "That is somebody else's team")
    }

    func testEveryRequirementCompiles() {
        // `setCodeSigningRequirement` raises on a string it cannot parse, so each
        // requirement is compiled before it is applied.
        for requirement in [BrimJobHelper.clientRequirement(), BrimJobHelper.daemonRequirement()] {
            XCTAssertTrue(
                BrimJobHelper.isWellFormed(requirement),
                "A requirement the system cannot evaluate: \(requirement)"
            )
        }
    }

    func testNonsenseIsRefusedRatherThanApplied() {
        XCTAssertFalse(BrimJobHelper.isWellFormed("anchor apple generic and and"))
        XCTAssertFalse(BrimJobHelper.isWellFormed("identifier"))
    }

    func testTheTwoDirectionsArePinnedSeparately() {
        // Two identities: checking the administrator process against the app's
        // identifier could never be satisfied.
        XCTAssertNotEqual(BrimJobHelper.clientRequirement(), BrimJobHelper.daemonRequirement())
    }

    /// The requirement names what the administrator process is signed as.
    func testTheAdministratorProcessIsPinnedToTheNameItIsSignedWith() {
        XCTAssertTrue(
            BrimJobHelper.daemonRequirement().contains("identifier \"\(BrimJobHelper.machServiceName)\""),
            BrimJobHelper.daemonRequirement()
        )
    }

    // MARK: - Shape

    func testNoProcessIdentifierUsage() throws {
        for file in Self.productSources() {
            // A Process handle may terminate its own timed-out child. It is
            // not an identity supplied by a peer or an authorization.
            var content = try String(contentsOf: file, encoding: .utf8)
            if ["ToolOutput.swift", "BoundedTool.swift"].contains(file.lastPathComponent) {
                content = content.replacingOccurrences(of: "kill(process.processIdentifier, SIGKILL)", with: "")
            }
            XCTAssertFalse(
                content.contains("processIdentifier"),
                "\(file.lastPathComponent) reads a process identifier. A pid is reused and "
                    + "can be raced; an authorisation decision has to come from the signature."
            )
        }
    }

    /// The approval rule rests on the service being reachable only inside
    /// Brim's process. An XPC listener would put it behind a connection again.
    func testNothingOpensAnXPCConnection() throws {
        var found: [String] = []
        for file in Self.productSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") {
                    continue
                }
                if ["NSXPCListener", "NSXPCConnection", "xpc_connection"].contains(where: code.contains) {
                    found.append("\(file.lastPathComponent): \(code)")
                }
            }
        }
        XCTAssertEqual(found, [], "Brim's service is in process; nothing should listen for it")
    }

    private static func productSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for directory in ["BrimCore/Sources", "Brim"] {
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil
            )
            while let entry = walker?.nextObject() as? URL {
                if entry.pathExtension == "swift" {
                    files.append(entry)
                }
            }
        }
        return files
    }
}

/// Anything Brim registers with macOS carries Brim's own identifier. The two
/// retired identifiers survive only so an upgrade can clear what they left,
/// and nothing new may be registered under them. Read from the sources,
/// since the registration sites cannot be imported.
final class RegisteredIdentifierTests: XCTestCase {
    /// Identifiers Brim answers to for cleanup and must never register under.
    private static let retired = ["com.google.Brim", "devplaceholder"]

    /// Everywhere Brim creates or names something macOS will persist.
    private static let registrationSites = ["scripts/build_release.sh"]

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Comments are stripped, since one may name a retired identifier to explain
    /// it.
    private static func code(of path: String) throws -> [(line: Int, text: String)] {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent(path),
                              encoding: .utf8)
        let marker = path.hasSuffix(".swift") ? "//" : "#"
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (line: $0.offset + 1,
                    text: String($0.element).components(separatedBy: marker).first ?? "") }
    }

    func testNothingRegistersUnderAnIdentifierBrimHasRetired() throws {
        for path in Self.registrationSites {
            for entry in try Self.code(of: path) {
                // One constant may hold the old name so an earlier agent can be cleared.
                guard !entry.text.contains("formerAgentLabel") else { continue }
                for retired in Self.retired where entry.text.contains(retired) {
                    XCTFail("\(path):\(entry.line) uses \(retired): "
                        + entry.text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }
}

/// A requirement naming only the team would let any helper the team signed
/// run as root, and a released helper must refuse a client that can be
/// attached to.
final class HelperPinningTests: XCTestCase {
    func testAPinnedRequirementNamesOneBuild() {
        let hash = "67e5308ce03f59f53ff6335f969667b0e17c29da"
        let pinned = BrimJobHelper.daemonRequirement(codeHash: hash)
        XCTAssertTrue(pinned.hasSuffix(" and cdhash H\"\(hash)\""), pinned)
        XCTAssertTrue(BrimJobHelper.isWellFormed(pinned))
        XCTAssertEqual(BrimJobHelper.daemonRequirement(codeHash: "not hex\" or anchor apple"),
                       BrimJobHelper.daemonRequirement(), "a malformed hash must not reach the requirement")
    }

    func testAClientOtherProgramsCanAttachToIsInjectable() {
        let hardened: UInt32 = 0x0001_0001
        XCTAssertFalse(TemporaryAdminChannel.isInjectable(status: hardened))
        XCTAssertTrue(TemporaryAdminChannel.isInjectable(status: 0x0000_0001), "no hardened runtime")
        XCTAssertTrue(TemporaryAdminChannel.isInjectable(status: hardened | 0x4), "get-task-allow")
        XCTAssertTrue(TemporaryAdminChannel.isInjectable(status: hardened | 0x1000_0000), "being debugged")
    }
}
