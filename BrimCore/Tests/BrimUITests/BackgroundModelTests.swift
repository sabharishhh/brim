import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// Picking background jobs for removal.
///
/// The rule worth protecting is what Brim refuses to offer. A launchd job
/// is a file and can be taken away. A background item is a row in a
/// database macOS owns, and the only tool it offers resets every
/// application's items at once, so offering a per item removal would be
/// promising something that cannot be delivered.
@MainActor
final class BackgroundSelectionTests: XCTestCase {

    private func job(_ label: String, record: String, exists: Bool = false) -> Registration {
        Registration(
            kind: .launchdJob, identifier: label, label: label, owningBundleID: label,
            programPath: nil, targetExists: exists, recordPath: record, evidence: "because"
        )
    }

    private func backgroundItem(_ label: String, exists: Bool = false) -> Registration {
        Registration(
            kind: .backgroundItem, identifier: label, label: label, owningBundleID: label,
            programPath: "/Applications/\(label).app", targetExists: exists,
            recordPath: nil, evidence: "because"
        )
    }

    func testOnlyJobFilesCanBePickedForRemoval() {
        XCTAssertTrue(BackgroundModel.isRemovable(
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/x.plist")
        ))
        XCTAssertFalse(BackgroundModel.isRemovable(backgroundItem("AppCleaner")),
                       "macOS owns that database and offers no way to remove one row")
    }

    func testASystemJobIsNeverOffered() {
        let apple = Registration(
            kind: .launchdJob, identifier: "com.apple.thing", label: "com.apple.thing",
            targetExists: false, recordPath: "/System/Library/LaunchDaemons/x.plist",
            evidence: "because", isSystemOwned: true
        )
        XCTAssertFalse(BackgroundModel.isRemovable(apple))
    }

    func testPickingAGroupPicksEveryFileUnderIt() {
        // Keystone installs the same job twice, once per domain. Ticking
        // the application means both copies, or the user removes one and
        // the other goes on sitting there.
        let model = BackgroundModel()
        let group = RegistrationGroup.group([
            job("com.google.keystone.agent", record: "/Users/me/Library/LaunchAgents/a.plist"),
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/a.plist")
        ])[0]

        model.toggle(group)

        XCTAssertEqual(model.selection.count, 2)
        XCTAssertTrue(model.isSelected(group))
        model.toggle(group)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testAGroupWithNothingRemovableCannotBePicked() {
        let model = BackgroundModel()
        let group = RegistrationGroup.group([backgroundItem("AppCleaner")])[0]
        XCTAssertFalse(model.canSelect(group))
    }

    func testTheIntentNamesThePlistsAndNotTheJobLabels() {
        // The planner works from paths. A label is not a file, and naming
        // one would produce a plan that removes nothing.
        let model = BackgroundModel()
        let group = RegistrationGroup.group([
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/a.plist")
        ])[0]
        model.toggle(group)

        // Nothing is selectable until a report has been loaded, since the
        // selection is resolved against it.
        XCTAssertNil(model.removalIntent(requesterIdentity: "tester"),
                     "A selection with no loaded report names nothing")
    }
}
