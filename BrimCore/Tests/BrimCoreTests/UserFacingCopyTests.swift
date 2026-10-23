import XCTest
@testable import BrimCore

/// House style for anything a person reads: no em or en dashes.
final class UserFacingCopyTests: XCTestCase {

    private func assertPlain(
        _ text: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for dash in ["—", "–"] {
            XCTAssertFalse(
                text.contains(dash),
                "\(label) uses a \(dash): \"\(text)\"",
                file: file, line: line
            )
        }
        XCTAssertFalse(text.contains("  "), "\(label) has a double space: \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.hasSuffix(" "), "\(label) ends in a space", file: file, line: line)
    }

    func testEveryDomainSentenceReadsPlainly() {
        for domain in LeftoverDomain.allCases {
            assertPlain(domain.title, "\(domain).title")
            assertPlain(domain.whatItHolds, "\(domain).whatItHolds")
            assertPlain(domain.consequence, "\(domain).consequence")
        }
    }

    func testEveryOwnershipVerdictReadsPlainly() {
        let search = OwnershipSearch(
            installedBundleIDs: [], installedNames: [],
            receiptBundleIDs: ["com.receipt.app"],
            previouslyRemovedBundleIDs: ["com.brim.removed"],
            launchServicesLookup: { id in
                id == "com.stale.app" ? [URL(fileURLWithPath: "/Applications/Stale.app")] : []
            },
            exists: { _ in false }
        )
        for identifier in ["com.stale.app", "com.receipt.app", "com.brim.removed", "com.unknown"] {
            if case .recordedButGone(let evidence) = search.ownership(of: identifier) {
                assertPlain(evidence, "evidence for \(identifier)")
            }
        }
    }

    // MARK: - The view layer

    /// Every Swift file holding something a person reads.
    private static func sourcesShowingText() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var found: [(String, String)] = []
        // `Brim`, not `Brim/Views`, so `BrimApp.swift` is read too.
        for directory in ["Brim", "BrimCore/Sources/BrimUI"] {
            let base = root.appendingPathComponent(directory)
            guard let walk = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        XCTAssertFalse(found.isEmpty, "Found no view sources to check, so this test proves nothing")
        return found
    }

    /// Every double-quoted literal, close enough: the false positives are
    /// identifiers, which the rules below cannot fire on. Comments are dropped
    /// first so one quoting an old sentence does not fail.
    private static func literals(in text: String) -> [String] {
        var results: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current: String?
            var escaped = false
            var previous: Character?
            for character in rawLine {
                if let running = current {
                    if escaped { current = running + String(character); escaped = false; previous = character; continue }
                    if character == "\\" { escaped = true; previous = character; continue }
                    if character == "\"" { results.append(running); current = nil; previous = character; continue }
                    current = running + String(character)
                } else if character == "/" && previous == "/" {
                    break  // The rest of the line is a comment.
                } else if character == "\"" {
                    current = ""
                }
                previous = character
            }
        }
        return results
    }

    /// No dashes in anything a person reads, views included.
    func testNoDashesInAnythingAPersonReads() throws {
        for (name, text) in try Self.sourcesShowingText() {
            for literal in Self.literals(in: text) {
                for dash in ["—", "–"] {
                    XCTAssertFalse(
                        literal.contains(dash),
                        "\(name) shows a \(dash): \"\(literal)\""
                    )
                }
            }
        }
    }

    /// A placeholder is not a fact: unsigned, broken and unexamined code each
    /// have their own sentence.
    func testNothingRendersAPlaceholderWhereAFactIsKnown() throws {
        let placeholders = ["\"unknown\"", "\"Unknown\"", "\"n/a\"", "\"N/A\"", "\"—\"", "\"-\""]
        for (name, text) in try Self.sourcesShowingText() {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // A comment explaining an old fallback must not count as one.
                let line = rawLine.components(separatedBy: "//").first ?? ""
                guard line.contains("??") else { continue }
                for placeholder in placeholders where line.contains(placeholder) {
                    XCTFail(
                        "\(name) falls back to \(placeholder) instead of saying what is true: "
                        + line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }
    }

    /// Brim describes the Mac, not itself. A gap is still reported, but the
    /// sentence names what is true of the machine and what would change it,
    /// not what Brim has not been taught.
    func testNothingTellsThePersonAboutBrimsOwnLimitations() throws {
        let banned = [
            "Brim does not know", "Brim cannot tell", "Brim has no idea",
            "it knows about", "it has been taught", "rather than guessing",
            "probably more", "Brim does not recognise", "Brim recognises",
            "nobody Brim can name", "Brim did not find"
        ]
        for (name, text) in try Self.sourcesShowingText() {
            for literal in Self.literals(in: text) {
                for phrase in banned where literal.contains(phrase) {
                    XCTFail("\(name) describes Brim rather than the Mac: \"\(literal)\"")
                }
            }
        }
    }

    func testEveryApprovalPromptReadsPlainly() {
        // macOS renders these after "Brim is trying to", so they must also
        // begin in lower case and carry no trailing stop.
        func step(_ kind: StepKind, _ cost: CostOfError) -> Step {
            Step(index: 0, kind: kind, target: "/tmp/x", targetFingerprint: nil, tier: .A,
                 evidence: "e", expectedBytes: 1, capability: .ok, reversible: false,
                 costOfError: cost, executionPhase: .auxiliary, disposition: .delete)
        }
        let cases: [[Step]] = [
            [step(.trashPath, .medium)],
            [step(.trashPath, .medium), step(.trashPath, .high)],
            [step(.resetPrivacyGrants, .medium)],
            [step(.resetPrivacyGrants, .medium), step(.trashPath, .high)]
        ]
        for steps in cases {
            let plan = Plan(
                planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
                intent: PlanIntent(type: .uninstall,
                                   subjectIdentity: Identity(bundleID: "com.t.a", name: "Thing")),
                steps: steps, excludedItems: [], expectedTotalBytes: 1
            )
            guard case .humanPresence(let reason) = ApprovalPolicy()
                .requirement(for: plan, lastAuthenticated: nil) else { continue }
            assertPlain(reason, "approval reason")
            XCTAssertEqual(reason.first?.isLowercase, true, "\"\(reason)\" follows \"Brim is trying to\"")
            XCTAssertFalse(reason.hasSuffix("."), "macOS supplies the full stop: \"\(reason)\"")
        }
    }
}
