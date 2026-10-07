import BrimPrivileged
import XCTest

/// Who is allowed to talk to whom, and the fact that anybody checks.
///
/// The requirement string named `com.google.Brim` and team `EQHXZ8M8AV`,
/// which belongs to Google, so nothing Brim signs could ever have matched
/// it. The debug branch had no anchor and no team, leaving a bare
/// identifier that any process can claim by naming itself.
///
/// The only connection Brim makes is to its temporary administrator
/// process, and `TemporaryAdminChannel` checks both ends against the
/// requirements `BrimJobHelper` builds. There was a second copy of these
/// for an XPC service the app no longer runs; it went with that service.
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
        // `setCodeSigningRequirement` raises rather than returns on a string
        // it cannot parse, so an unparseable requirement is a crash, not a
        // refusal. Each one is compiled before it is ever applied.
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
        // The first attempt at this had the app checking the administrator
        // process against the app's own identifier, which nothing could
        // ever satisfy.
        XCTAssertNotEqual(BrimJobHelper.clientRequirement(), BrimJobHelper.daemonRequirement())
    }

    /// The requirement has to name what the administrator process is
    /// signed as. An earlier copy named a daemon deleted months before.
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
            if file.lastPathComponent == "ToolOutput.swift" {
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
    /// Brim's process. An XPC listener would put it on the far side of a
    /// connection again, with a client that has to be authenticated, and
    /// the last one was kept for months after nothing used it.
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

/// Anything Brim registers with macOS carries Brim's own identifier.
///
/// `SafetyChecker` reads Brim's identifier from its own bundle because a
/// hardcoded list once named `com.google.Brim` and a `devplaceholder`
/// identifier, matched neither the real application nor anything else, and
/// silently blocked self-removal. Those two survive only so an upgrade can
/// clear what they left behind.
///
/// What nothing held is the other direction: that Brim never registers
/// something *new* under one of them. It was doing exactly that. `brim
/// energy --register` installed a launch agent labelled
/// `com.google.Brim.energy`, with RunAtLoad and KeepAlive set, and
/// `build_release.sh` stamped `com.google.Brim` on the bundle it built. A
/// utility whose whole subject is background agents nobody can account for
/// cannot be the thing installing one.
///
/// Read from the sources, because the registration sites are an executable
/// target and a shell script, neither of which a test can import. The same
/// approach `StepVocabularyTests` uses on the planner.
final class RegisteredIdentifierTests: XCTestCase {
    /// Identifiers Brim answers to for cleanup and must never register under.
    private static let retired = ["com.google.Brim", "devplaceholder"]

    /// Everywhere Brim creates or names something macOS will persist.
    ///
    /// One entry, since the command line tool went. It was the only part of
    /// Brim that registered a launch agent, which is why removing it was
    /// worth doing on its own: a utility whose subject is software running
    /// when nobody asked it to should not leave an agent behind.
    private static let registrationSites = ["scripts/build_release.sh"]

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Each line with its comment stripped, because a comment may name a
    /// retired identifier in order to explain it, and the commit that
    /// removed these did exactly that.
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
                // One constant is allowed to hold the old name, so that
                // `--unregister` can clear an agent an earlier build left.
                guard !entry.text.contains("formerAgentLabel") else { continue }
                for retired in Self.retired where entry.text.contains(retired) {
                    XCTFail("\(path):\(entry.line) uses \(retired): "
                        + entry.text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }

    // `testTheEnergyAgentIsNamedAfterBrim` went with the command line
    // tool. There is no energy agent now, and nothing in the product
    // registers one.
}
