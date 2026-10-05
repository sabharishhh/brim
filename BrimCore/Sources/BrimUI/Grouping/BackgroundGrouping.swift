import BrimCore
import Foundation

/// Limits this page to registrations with an application association.
/// The complete report remains available to inspection and uninstall planning.
enum BackgroundScope {
    static func registrations(
        _ records: [Registration], applications: [InstalledApplication]
    ) -> [Registration] {
        let identifiers = Set(applications
            .filter { !$0.isSystemProtected }
            .flatMap(\.identity.searchBundleIdentifiers)
            .map { $0.lowercased() })
        let appOwners = Set(records.filter {
            $0.kind == .backgroundItem && !$0.isSystemOwned && hasApplicationPath($0)
        }.compactMap { record in
            record.owningBundleID.map { ownerKey($0, namespace: record.namespace) }
        })
        return records.filter { record in
            guard !record.isSystemOwned, record.kind != .shellProfileLine else { return false }
            if hasApplicationPath(record) {
                return true
            }
            if [record.owningBundleID, record.identifier].compactMap(\.self).contains(where: {
                identifiers.contains($0.lowercased())
            }) {
                return true
            }
            guard record.kind == .backgroundItem, let owner = record.owningBundleID else { return false }
            return appOwners.contains(ownerKey(owner, namespace: record.namespace))
        }
    }

    private static func hasApplicationPath(_ record: Registration) -> Bool {
        [record.programPath, record.recordPath].compactMap(\.self).contains { path in
            guard path.hasPrefix("/") else { return false }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let protectedRoots = ["/System", "/Library/Apple/System", "/usr", "/bin", "/sbin"]
            guard !protectedRoots.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") })
            else { return false }
            return normalized.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
        }
    }

    private static func ownerKey(_ owner: String, namespace: String?) -> String {
        "\(namespace ?? ""):\(owner.lowercased())"
    }
}

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
        /// Retained records with no automatic removal route.
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

/// Separates missing actionable targets from declarations and retained records.
/// A declaration or a file on disk does not establish that a process is running.
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
                GroupRule(id: "gone", title: "App not found", matches: { $0.state == .gone }, order: byName),
                GroupRule(
                    id: "clearing", title: "Still listed", collapsed: true,
                    matches: { $0.state == .clearing || $0.group.items.allSatisfy { $0.isStale && $0.isReportOnly } },
                    order: byName
                ),
                GroupRule(id: "login", title: "Listed at login", matches: \.opensAtLogin, order: byName),
                GroupRule(
                    id: "background", title: "Background registrations", matches: \.runsInBackground, order: byName
                )
            ],
            otherwise: GroupRule(
                id: "other", title: "Extensions and permissions", matches: { _ in true }, order: byName
            ),
            display: ["gone", "login", "background", "other", "clearing"]
        )
    }
}
