import BrimCore
import Foundation
import SQLite3

/// Privacy permissions macOS still holds for programs that are gone.
///
/// Found on this Mac on 6 October: Full Disk Access listed
/// `com.microsoft.autoupdate.helper`, whose file in
/// `/Library/PrivilegedHelperTools` had been removed with Microsoft
/// AutoUpdate. Settings showed it with a blank icon and Show in Finder did
/// nothing, and nothing in Brim mentioned it. A permission granted to a
/// program path outlives the program: the privacy database keeps the row
/// until someone removes it.
///
/// Only those are reported: a permission, on or switched off, for a path
/// that is no longer on the disk. System Settings lists them in the pane
/// for their service, and its minus button removes them: on 7 October the
/// Microsoft helper's switched-off Full Disk Access entry was removed that
/// way. Brim had told the person only to look in Privacy & Security, which
/// has a dozen panes, and was then wrongly changed to hide switched-off
/// entries on the belief that Settings did not show them. Each row now
/// names its pane and whether it is on, and opens that pane.
///
/// Read only. The privacy database belongs to macOS; Brim never writes to
/// it (`CLAUDE.md`: no private database edits), so each row is report-only
/// and names the pane in System Settings where it can be removed.
public struct PrivacyGrantSurface: RegistrationSurface {
    public let kind: Registration.Kind = .privacyGrant

    public init() {}

    /// The machine's database, where Full Disk Access and Accessibility
    /// live, and the person's own.
    private func databases(in root: FileSystemRoot) -> [URL] {
        [
            root.rootURL.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            root.url(for: .userApplicationSupport).appendingPathComponent("com.apple.TCC/TCC.db")
        ]
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        guard let system = databases(in: root).first, FileManager.default.fileExists(atPath: system.path) else {
            return .available(kind)
        }
        return Self.rows(in: system) == nil
            ? .unavailable(kind, "Privacy permissions could not be read.", absence: .needsPermission)
            : .available(kind)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        var services: [String: Set<String>] = [:]
        var allowed: Set<String> = []
        for database in databases(in: root) {
            for row in Self.rows(in: database) ?? [] where row.isPath {
                services[row.client, default: []].insert(row.service)
                if row.isAllowed {
                    allowed.insert(row.client)
                }
            }
        }
        return services.keys.sorted().compactMap { path in
            let target = root.rootURL.path == "/" ? path : root.rootURL.appendingPathComponent(path).path
            let presence = PathObservation.observe(target)
            // A program that is still there is the person's business, not a
            // leftover.
            guard presence.isAbsent else { return nil }
            let held = (services[path] ?? []).sorted()
            let panes = held.compactMap(Self.paneName)
            let listed = panes.isEmpty ? "Privacy & Security" : panes.joined(separator: " and ")
            let state = allowed.contains(path) ? "switched on" : "switched off"
            let name = URL(fileURLWithPath: path).lastPathComponent
            return Registration(
                kind: .privacyGrant,
                identifier: "privacy:" + path,
                label: name,
                owningBundleID: PrivilegedHelperToolSurface.probableOwner(label: name),
                programPath: path,
                targetExists: false,
                evidence: "\(listed) lists this program, \(state), but it is no longer on this Mac.",
                isSystemOwned: path.hasPrefix("/System/") || path.hasPrefix("/usr/"),
                capability: .refusedByOS,
                targetPresence: presence,
                // The services, so the inspector can open the right pane.
                recordIdentity: held.joined(separator: ","),
                namespace: "privacy"
            )
        }
    }

    // MARK: - Reading

    struct Row: Equatable {
        let service: String
        let client: String
        /// `client_type` 1 is a path; 0 is a bundle identifier.
        let isPath: Bool
        /// `auth_value` 2 is allowed and 3 limited; 0 is switched off.
        var isAllowed = true
    }

    /// Nil when the database could not be opened, which without Full Disk
    /// Access is every time.
    static func rows(in database: URL) -> [Row]? {
        var handle: OpaquePointer?
        let uri = "file:" + database.path + "?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let query = "SELECT service, client, client_type, auth_value FROM access"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil)
            == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = sqlite3_column_text(statement, 0), let client = sqlite3_column_text(statement, 1)
            else { continue }
            rows.append(Row(
                service: String(cString: service), client: String(cString: client),
                isPath: sqlite3_column_int(statement, 2) == 1,
                isAllowed: [2, 3].contains(sqlite3_column_int(statement, 3))
            ))
        }
        return rows
    }

    /// What System Settings calls each service, for the ones it lists.
    static func paneName(_ service: String) -> String? {
        switch service {
        case "kTCCServiceSystemPolicyAllFiles": "Full Disk Access"
        case "kTCCServiceAccessibility": "Accessibility"
        case "kTCCServiceScreenCapture": "Screen & System Audio Recording"
        case "kTCCServiceListenEvent": "Input Monitoring"
        case "kTCCServiceDeveloperTool": "Developer Tools"
        case "kTCCServiceAppleEvents": "Automation"
        case "kTCCServiceCamera": "Camera"
        case "kTCCServiceMicrophone": "Microphone"
        case "kTCCServiceSystemPolicyAppBundles": "App Management"
        default: nil
        }
    }
}
