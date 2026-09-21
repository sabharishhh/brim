import Foundation

/// Preferences, which do not go away just because the file did.
///
/// `cfprefsd` holds preference domains in memory and owns the files on
/// disk. Unlinking a `.plist` without telling the daemon leaves it holding
/// the domain, and the next time anything touches that domain the daemon
/// writes the file straight back out. An uninstall that only removed the
/// file can watch it reappear, which reads as Brim having failed when what
/// actually happened is that Brim asked the wrong component.
///
/// So the domain is removed through the preferences API as well as the
/// file being trashed. Both, in that order: the API call invalidates the
/// daemon's copy, and the trash step is what makes the removal
/// recoverable.
public enum PreferenceDomains {

    /// Whether a path is a preferences file, and which domain it holds.
    ///
    /// Only files directly inside a `Preferences` folder count.
    /// `ByHost` ones carry a hardware UUID in the name and are handled by
    /// stripping it, because the domain is the part before.
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
        if UUID(uuidString: candidate) != nil { return true }
        return candidate.count == 12
            && candidate.allSatisfy { $0.isHexDigit }
    }

    /// Tells `cfprefsd` to forget a domain.
    ///
    /// Deliberately not a delete of anything: this clears the daemon's
    /// copy so it stops writing the file back. The file itself goes to
    /// the Trash through the ordinary step, which is what keeps the
    /// removal undoable.
    ///
    /// Best effort by design. Failing to invalidate a cache must never
    /// abandon an uninstall whose files are already gone; the journal
    /// records it and the person is told the preference may return.
    @discardableResult
    public static func forget(_ domain: String) -> Bool {
        guard isPlausibleDomain(domain) else { return false }
        let application = domain as CFString

        // Both host scopes. A ByHost plist and an ordinary one are the
        // same domain to an application and two separate stores to the
        // daemon, so clearing one and not the other leaves half of it
        // cached and half of it written back.
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

    /// Guards against handing `cfprefsd` something that is not a domain.
    ///
    /// `kCFPreferencesAnyApplication` and the global domain are the two
    /// that would do real damage: clearing `.GlobalPreferences` resets
    /// system-wide settings that belong to no application at all.
    public static func isPlausibleDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.contains("."), !domain.contains("/") else { return false }
        let forbidden = [
            ".globalpreferences",
            "kcfpreferencesanyapplication",
            "apple.global.domain",
        ]
        return !forbidden.contains(domain.lowercased())
    }
}
