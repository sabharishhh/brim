import XCTest
import BrimCore

/// What a screen reader is handed for a row.
///
/// Both lists build a row out of half a dozen separate pieces of text, and
/// left alone the accessibility tree passes all of them on as unrelated
/// fragments: a name, then a category, then a warning, then a sentence,
/// then a path, with nothing saying they describe one thing. Worse, a
/// selectable path arrived twice, because `textSelection` adds a child of
/// its own. These compose the row into one sentence instead.
///
/// The rule the tests hold: the label says what the thing is, the value
/// carries the measurement or the location. A path read aloud in the
/// middle of every entry buries the part that matters.
final class SpokenDescriptionTests: XCTestCase {

    private func registration(
        _ label: String, kind: Registration.Kind = .launchdJob,
        exists: Bool = true, record: String? = nil, signing: SigningState? = nil
    ) -> Registration {
        Registration(
            kind: kind, identifier: label, label: label, owningBundleID: label,
            programPath: nil, targetExists: exists, recordPath: record,
            evidence: "An empty job file in the user domain.", signing: signing
        )
    }

    func testAnEntryReadsAsOneSentence() {
        let spoken = registration("com.google.keystone.agent", exists: false,
                                  record: "/Library/LaunchAgents/x.plist").spokenDescription

        XCTAssertTrue(spoken.contains("com.google.keystone.agent"))
        XCTAssertTrue(spoken.contains("Background job"))
        XCTAssertTrue(spoken.contains("points at nothing"))
        XCTAssertTrue(spoken.contains("An empty job file"))
    }

    func testThePathIsTheValueAndNotTheLabel() {
        let entry = registration("com.google.keystone.agent", exists: false,
                                 record: "/Library/LaunchAgents/x.plist")

        XCTAssertFalse(entry.spokenDescription.contains("/Library/LaunchAgents"),
                       "A path read aloud inside every label buries the rest of it")
        XCTAssertEqual(entry.spokenLocation, "/Library/LaunchAgents/x.plist")
    }

    func testTwoCopiesOfOneJobAreToldApartByTheirValue() {
        // Keystone installs the same job in both domains. The labels are
        // identical by nature, so the location has to carry the difference.
        let user = registration("com.google.keystone.agent", exists: false,
                                record: "/Users/me/Library/LaunchAgents/x.plist")
        let local = registration("com.google.keystone.agent", exists: false,
                                 record: "/Library/LaunchAgents/x.plist")

        XCTAssertNotEqual(user.spokenLocation, local.spokenLocation)
    }

    func testWhatMacOSWillClearSaysSoRatherThanRaisingAnAlarm() {
        let item = registration("AppCleaner", kind: .backgroundItem, exists: false)
        XCTAssertTrue(item.spokenDescription.contains("macOS will drop this"))
        XCTAssertFalse(item.spokenDescription.contains("points at nothing"))
    }

    func testATroubledSignatureIsSpokenAndAGoodOneIsNot() {
        let changed = registration("Helper", signing: .teamChanged(recorded: "AAA", found: "BBB"))
        XCTAssertTrue(changed.spokenDescription.contains("AAA"))

        let fine = registration("Helper", signing: .valid(team: "AAA"))
        XCTAssertFalse(fine.spokenDescription.contains("AAA"),
                       "A line on every row saying the signature is fine is a line nobody reads")
    }

    func testAGroupHeaderNamesTheApplicationAndWhatIsUnderIt() {
        let group = RegistrationGroup.group([
            registration("com.google.keystone.agent", exists: false, record: "/a.plist"),
            registration("com.google.keystone.agent", exists: false, record: "/b.plist")
        ])[0]

        let spoken = group.spokenDescription
        XCTAssertTrue(spoken.contains("com.google.keystone.agent"))
        XCTAssertTrue(spoken.contains("2 background jobs"))
        XCTAssertTrue(spoken.contains("point at nothing"))
    }

    func testNothingSpokenIsEmptyOrTrailsOff() {
        // An empty label leaves a reader on an element that says nothing,
        // which is how the selection checkboxes read before they were named.
        for entry in [
            registration("a"),
            registration("b", kind: .backgroundItem, exists: false),
            registration("c", signing: .unsigned)
        ] {
            XCTAssertFalse(entry.spokenDescription.isEmpty)
            XCTAssertFalse(entry.spokenDescription.hasPrefix("."))
            XCTAssertFalse(entry.spokenDescription.contains(".."))
        }
    }
}
