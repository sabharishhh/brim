import Foundation

/// Preferences, which do not go away with the file. `cfprefsd` holds each
/// domain in memory and writes the file back if the plist is unlinked while
/// it still holds it. So the domain is cleared through the preferences API
/// first, then the file goes to the Trash, which keeps the removal undoable.
public enum PreferenceDomains {
    /// Whether a path is a preferences file directly inside a `Preferences`
    /// folder, and its domain. A ByHost file's hardware UUID is stripped.
    public static func domain(forPlistAt path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "plist" else { return nil }

        let parent = url.deletingLastPathComponent().lastPathComponent
        guard parent == "Preferences" || parent == "ByHost" else { return nil }

        var name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        if parent == "ByHost" {
            // com.example.app.00000000-0000-1000-8000-XXXXXXXXXXXX.plist
            let parts = name.split(separator: ".")
            if let last = parts.last, isHardwareIdentifier(String(last)) {
                name = parts.dropLast().joined(separator: ".")
            }
        }
        guard !name.isEmpty, name.contains(".") else { return nil }
        return name
    }

    /// A ByHost suffix: a UUID, or the older bare MAC address form.
    static func isHardwareIdentifier(_ candidate: String) -> Bool {
        if UUID(uuidString: candidate) != nil {
            return true
        }
        return candidate.count == 12
            && candidate.allSatisfy(\.isHexDigit)
    }

    /// Tells `cfprefsd` to forget a domain, so it stops writing the file back.
    /// Deletes nothing itself. Best effort: failing to clear a cache must never
    /// abandon an uninstall, and the journal records it.
    @discardableResult
    public static func forget(_ domain: String) -> Bool {
        guard isPlausibleDomain(domain) else { return false }
        let application = domain as CFString

        // Both host scopes: one domain to the app, two stores to the daemon.
        var cleared = false
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            let keys = CFPreferencesCopyKeyList(
                application, kCFPreferencesCurrentUser, host
            ) as? [CFString]
            guard let keys, !keys.isEmpty else { continue }
            CFPreferencesSetMultiple(
                nil, keys as CFArray, application, kCFPreferencesCurrentUser, host
            )
            if CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, host) {
                cleared = true
            }
        }

        // Nothing cached is success: there is no stale copy to write back.
        return cleared || CFPreferencesCopyKeyList(
            application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) == nil
    }

    /// A property list holding an empty dictionary: what `cfprefsd` writes for a
    /// cleared domain. It holds no settings.
    public static func isEmptyStub(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4096,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist.isEmpty
    }

    /// Removes the empty copy `cfprefsd` writes back about nine seconds after a
    /// domain is cleared and its file trashed. Only an empty dictionary is
    /// removed; a file that comes back with settings is reported, not hidden.
    public static func removeEmptyWriteBack(at paths: [String], within seconds: TimeInterval = 15) async {
        var waiting = Set(paths)
        let deadline = Date().addingTimeInterval(seconds)
        while !waiting.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            for path in waiting where FileManager.default.fileExists(atPath: path) {
                if isEmptyStub(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
                waiting.remove(path)
            }
        }
    }

    public static func isPlausibleDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.contains("."), !domain.contains("/") else { return false }
        let forbidden = [
            ".globalpreferences",
            "kcfpreferencesanyapplication",
            "apple.global.domain"
        ]
        return !forbidden.contains(domain.lowercased())
    }
}
