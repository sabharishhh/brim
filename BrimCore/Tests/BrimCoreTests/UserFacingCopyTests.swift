import XCTest
@testable import BrimCore

/// House style for anything a person reads.
///
/// Em and en dashes are the giveaway of text written by a model rather than
/// by someone explaining their own software, and once a few creep in the
/// whole app starts to read the same way. Every sentence Brim shows should
/// sound like a person who knows what the software does telling you plainly.
///
/// This covers the copy that lives in the model layer, where the reusable
/// sentences are. Copy in a view is caught by reading it.
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
        for directory in ["Brim/Views", "BrimCore/Sources/BrimUI"] {
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

    /// Every double-quoted literal in a file, which is close enough: the
    /// false positives are identifiers and symbol names, and neither of the
    /// rules below can fire on those.
    ///
    /// Comments are dropped first. A comment recording what a sentence used
    /// to say, which is how this codebase explains its own fixes, otherwise
    /// fails the very rule it is documenting.
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

    /// The house rule applied where it was not being applied.
    ///
    /// This file used to say "copy in a view is caught by reading it", and
    /// reading it is exactly what stopped happening. What it missed: an em
    /// dash standing in for a table cell with no value, two sentences left
    /// unfinished by an edit, an empty state explaining which caches Brim had
    /// been taught about, and a footprint total that guessed it was "probably
    /// more". None of that is in the model layer, so none of it was covered.
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

    /// A placeholder is not a fact.
    ///
    /// `group.signedBy ?? "—"` rendered unsigned code, a broken signature and
    /// code Brim never examined as the same blank cell, and the energy list
    /// grew a row called Unknown with real joules against it. Every one of
    /// those states is knowable, and each one has its own sentence already.
    func testNothingRendersAPlaceholderWhereAFactIsKnown() throws {
        let placeholders = ["\"unknown\"", "\"Unknown\"", "\"n/a\"", "\"N/A\"", "\"—\"", "\"-\""]
        for (name, text) in try Self.sourcesShowingText() {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // Same reason as `literals`: a comment explaining an old
                // fallback must not count as one.
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

    /// Brim describes the Mac, not itself.
    ///
    /// The rule is not that a gap goes unreported. `RegistrationCoverage` and
    /// `ScanCompleteness` exist precisely so a surface that could not be read
    /// says so, and a zero nobody measured is still a lie. The rule is that
    /// the sentence names what is true of the machine and what would change
    /// it, rather than announcing what Brim has not been taught or cannot
    /// work out. "Brim did not find any of the build caches it knows about"
    /// told somebody about Brim's table. "Nothing for the build tools to give
    /// back" tells them about their disk.
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
