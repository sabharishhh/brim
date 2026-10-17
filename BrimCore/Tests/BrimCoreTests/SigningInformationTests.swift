import XCTest
import Security
@testable import BrimCore

/// Two modules ask macOS who signed a bundle and must ask the same question.
/// The team identifier is signing information and needs
/// `kSecCSSigningInformation`; asking for requirement information alone left
/// every `Identity.teamID` nil, and every team-prefixed rule read as
/// "nothing found" rather than "never asked".
final class SigningInformationTests: XCTestCase {

    /// Read from the source: every caller asks for signing information, or the
    /// team identifier is not in the dictionary it gets back.
    func testEverySigningInformationCallAsksForSigningInformation() throws {
        var callers = 0
        for file in Self.productSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("SecCodeCopySigningInformation") else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("SecCodeCopySigningInformation") {
                callers += 1
                let flags = Self.flagExpression(around: line, in: text)
                XCTAssertTrue(
                    flags.contains("kSecCSSigningInformation"),
                    "\(file.lastPathComponent):\(offset + 1) reads signing information without "
                    + "asking for it. The team identifier will be nil and nothing will say so."
                )
            }
        }
        XCTAssertGreaterThan(
            callers, 0,
            "No caller found at all. If the call was renamed this test is now watching nothing."
        )
    }

    /// The two readers agree on whatever this machine has. Apple's binaries
    /// carry no team identifier, so this needs a third-party application; the
    /// source scan above still holds the invariant without one.
    func testTheTwoReadersAgreeOnTheSameBundle() async throws {
        let applications = URL(fileURLWithPath: "/Applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        guard let bundle = names.filter({ $0.hasSuffix(".app") })
            .map({ applications.appendingPathComponent($0) })
            .first(where: { Self.teamIdentifier(of: $0) != nil })
        else {
            throw XCTSkip("No third-party application on this Mac to compare the two readings on.")
        }

        let expected = Self.teamIdentifier(of: bundle)
        let resolved = await IdentityResolver(
            root: FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        ).resolve(bundleURL: bundle).teamID

        XCTAssertEqual(
            resolved, expected,
            "\(bundle.lastPathComponent): macOS reports team \(expected ?? "none") and "
            + "IdentityResolver reports \(resolved ?? "none")."
        )
    }

    // MARK: - Helpers

    /// Read the plain way, so the test does not prove a reading by repeating it.
    private static func teamIdentifier(of bundle: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The flags a call site passes, as a literal or a constant bound on the
    /// line above.
    private static func flagExpression(around line: Substring, in text: String) -> String {
        if line.contains("SecCSFlags") { return String(line) }
        // `let wanted = SecCSFlags(...)` then `…(code, wanted, &info)`.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(of: line) else { return String(line) }
        let start = max(0, index - 4)
        return lines[start...index].joined(separator: "\n")
    }

    private static func productSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BrimCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BrimCore
            .deletingLastPathComponent()   // repo
        var files: [URL] = []
        for directory in ["BrimCore/Sources", "Brim"] {
            let url = root.appendingPathComponent(directory)
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let entry = walker?.nextObject() as? URL {
                if entry.pathExtension == "swift" { files.append(entry) }
            }
        }
        return files
    }
}
