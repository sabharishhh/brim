import XCTest
@testable import BrimService
import BrimProtocol
import BrimCore
import BrimPrivileged

/// Who is allowed to talk to whom, and the fact that anybody checks.
///
/// The requirement string named `com.google.Brim` and team `EQHXZ8M8AV`,
/// which belongs to Google, so nothing Brim signs could ever have matched
/// it. The debug branch had no anchor and no team, leaving a bare
/// identifier that any process can claim by naming itself. And none of it
/// ran anyway: every call site the product actually uses passed
/// `requireCodeSigning: false`.
final class XPCAuthenticationTests: XCTestCase {

    // MARK: - The requirement itself

    func testTheRequirementNamesThisApplicationAndThisTeam() {
        let requirement = MutualAuthentication.requirement(for: .application)

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
        for peer in BrimPeer.allCases {
            let requirement = MutualAuthentication.requirement(for: peer)
            XCTAssertTrue(
                MutualAuthentication.isWellFormed(requirement),
                "\(peer) has a requirement the system cannot evaluate: \(requirement)"
            )
        }
    }

    func testNonsenseIsRefusedRatherThanApplied() {
        XCTAssertFalse(MutualAuthentication.isWellFormed("anchor apple generic and and"))
        XCTAssertFalse(MutualAuthentication.isWellFormed("identifier"))
    }

    func testTheTwoDirectionsArePinnedSeparately() {
        // The first attempt at this had the app checking the daemon against
        // the app's own identifier, which nothing could ever satisfy.
        XCTAssertNotEqual(
            MutualAuthentication.requirement(for: .application),
            MutualAuthentication.requirement(for: .daemon)
        )
    }

    /// `BrimPrivileged` deliberately depends on nothing, so it builds its
    /// own copy of this string. Two copies is how three different team
    /// identifiers ended up in one codebase, so they are held together
    /// here instead.
    func testThePrivilegedHelperAgreesAboutWhoBrimIs() {
        XCTAssertEqual(BrimJobHelper.teamID, MutualAuthentication.teamID)
        XCTAssertEqual(
            BrimJobHelper.clientRequirement(),
            MutualAuthentication.requirement(for: .application),
            "The root daemon and the rest of the product disagree about what Brim's "
            + "application is, which is exactly how this broke the first time."
        )
    }

    /// The other direction, which was the one left unheld.
    ///
    /// This test's neighbour bound the two copies of the *application*
    /// requirement together and stopped there, so the daemon half drifted
    /// unnoticed. `BrimPeer.daemon` named `com.sabharishhh.brim.daemon`,
    /// which was the full-service root daemon deleted in 0de063c; the daemon
    /// Brim actually ships is signed `com.sabharishhh.brim.jobhelper`, which
    /// `BrimJobHelper.daemonRequirement` had right the whole time. Verified
    /// against the built binary, the requirement as written could not be
    /// satisfied by anything Brim produces, which is the identical failure
    /// mode as the original `com.google.Brim` string.
    func testThePrivilegedHelperAgreesAboutWhichDaemonIsBrims() {
        XCTAssertEqual(
            BrimJobHelper.daemonRequirement(),
            MutualAuthentication.requirement(for: .daemon),
            "The two copies of the daemon requirement name different identifiers, so one "
            + "of them pins something nothing is signed as."
        )
    }

    /// The requirement has to name the service the daemon actually listens
    /// on, because that is the name the signature carries.
    func testTheDaemonIsPinnedToTheNameItIsSignedWith() {
        XCTAssertEqual(BrimPeer.daemon.signingIdentifier, BrimJobHelper.machServiceName)
    }

    // MARK: - Enforcement

    func testAPeerThatCannotSatisfyTheRequirementIsRejected() async throws {
        // The test bundle is signed for testing, not as Brim, so it cannot
        // satisfy a requirement pinned to the application. The connection
        // is meant to die rather than be served.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realService = BrimService(
            root: FileSystemRoot(rootURL: tempDir),
            brimAppURL: tempDir.appendingPathComponent("Brim.app"),
            planStoreDirectory: tempDir.appendingPathComponent("Plans"),
            journalStoreDirectory: tempDir.appendingPathComponent("Journal")
        )

        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, accepting: .brim(.application))
        listener.delegate = delegate
        listener.resume()

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        let client = try BrimXPCClient(connection: connection, expecting: .brim(.application))

        do {
            _ = try await client.inspect(identity: Identity(bundleID: "com.apple.Safari", name: "Safari"))
            XCTFail("A peer that is not Brim was served")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, 4097, "Expected the connection to be torn down")
        }
    }

    func testAnUnpinnableConnectionIsNotHandedBack() {
        // A listener whose requirement will not compile must refuse, not
        // serve. Verified through the delegate rather than by inspection,
        // because the old code applied the requirement and then returned
        // true whatever happened.
        let connection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        XCTAssertTrue(MutualAuthentication.pin(connection, to: .brim(.application)))
        connection.invalidate()
    }

    // MARK: - Shape

    func testNoProcessIdentifierUsage() throws {
        for file in Self.productSources() {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                content.contains("processIdentifier"),
                "\(file.lastPathComponent) reads a process identifier. A pid is reused and "
                + "can be raced; an authorisation decision has to come from the signature."
            )
        }
    }

    /// The regression guard that matters most. `requireCodeSigning: false`
    /// was passed at four of the five call sites, and nobody had to think
    /// about it at any of them, so the bool is gone and the only way to opt
    /// out is to name the anonymous same-process case out loud.
    func testOnlyTheSameProcessCaseSkipsPinning() throws {
        var unpinned: [String] = []
        for file in Self.productSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                // Prose about the old bool is not the old bool.
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if line.contains("requireCodeSigning") {
                    unpinned.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
                guard line.contains(".sameProcessAnonymous") else { continue }
                // Only the CLI's own in-process listener may say this, and
                // the file that declares the case. Matched on the path, not
                // the basename: there are three main.swift in this tree and
                // two of them talk to a real daemon.
                let permitted = ["BrimCLI/main.swift", "Security/MutualAuthentication.swift"]
                if !permitted.contains(where: { file.path.hasSuffix($0) }) {
                    unpinned.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(unpinned, [], "Something ships an XPC connection that nobody authenticates")
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
                if entry.pathExtension == "swift" { files.append(entry) }
            }
        }
        return files
    }
}
