import BrimCore
import Foundation

/// One application's registrations as a row on the Background page, with
/// which of the model's three lists it came from.
///
/// The same application can be in two of them at once, one job pointing
/// at nothing and another still running, so the list it came from is part
/// of its identity: two rows, never one row claiming both.
public struct BackgroundEntry: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable {
        /// Points at a program that is not there, and stays until removed.
        case gone
        /// Points at nothing, but macOS drops it by itself.
        case clearing
        /// Points at software that is installed.
        case present
    }

    public let group: RegistrationGroup
    public let state: State

    public init(group: RegistrationGroup, state: State) {
        self.group = group
        self.state = state
    }

    public var id: String {
        "\(state.rawValue):\(group.id)"
    }

    /// A login item, as its own record says. Not "points at an app":
    /// every application with helpers has a record like that.
    public var opensAtLogin: Bool {
        group.items.contains(where: \.launchesAtLogin)
    }

    /// An agent, daemon or helper: something that runs with no window.
    public var runsInBackground: Bool {
        group.items.contains { [.launchdJob, .backgroundItem, .privilegedHelper].contains($0.kind) }
    }
}

/// The Background page's groups, answering "should this be running?"
/// (plan §8): what points at nothing first, then what opens at login, then
/// what runs unseen, then extensions and permissions. What macOS is about
/// to tidy by itself comes last and closed, because there is nothing to do.
public enum BackgroundGrouper {
    public static func groups(
        stale: [RegistrationGroup], clearing: [RegistrationGroup], live: [RegistrationGroup]
    ) -> [ItemGroup<BackgroundEntry>] {
        let entries = stale.map { BackgroundEntry(group: $0, state: .gone) }
            + clearing.map { BackgroundEntry(group: $0, state: .clearing) }
            + live.map { BackgroundEntry(group: $0, state: .present) }
        let byName: (BackgroundEntry, BackgroundEntry) -> Bool = {
            $0.group.displayName.localizedStandardCompare($1.group.displayName) == .orderedAscending
        }
        return Grouping.assign(
            entries,
            rules: [
                GroupRule(id: "gone", title: "Points at nothing", matches: { $0.state == .gone }, order: byName),
                GroupRule(
                    id: "clearing", title: "macOS is tidying", collapsed: true,
                    matches: { $0.state == .clearing }, order: byName
                ),
                GroupRule(id: "login", title: "Opens at login", matches: \.opensAtLogin, order: byName),
                GroupRule(
                    id: "background", title: "Runs in the background", matches: \.runsInBackground, order: byName
                )
            ],
            otherwise: GroupRule(
                id: "other", title: "Extensions and permissions", matches: { _ in true }, order: byName
            ),
            display: ["gone", "login", "background", "other", "clearing"]
        )
    }
}
