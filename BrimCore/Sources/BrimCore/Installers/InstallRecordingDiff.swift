import Foundation

/// The second snapshot less the first, attributed.
///
/// Timing alone is not ownership: anything else running during the
/// recording writes too. So an item is linked to the install only when it
/// is named for one of the apps that appeared, comes from the same
/// developer, or was registered by it. Something named for another
/// installed app is that app's and is only counted. Whatever is left is
/// shown unticked, because only the person knows whether it came with the
/// install.
public enum InstallRecordingDiff {
    public static func result(
        before: InstallSnapshot, after: InstallSnapshot, installed: [InstallClaimant]
    ) -> InstallRecordingResult {
        let apps = recordedApps(before: before, after: after)
        let bundles = apps.map(\.path)
        // Outermost first, so a new folder is one row and not one per file.
        var fresh: [String] = []
        for path in after.paths.subtracting(before.paths).sorted(by: { $0.count < $1.count }) {
            guard !fresh.contains(where: { path.hasPrefix($0 + "/") }),
                  !bundles.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  !after.apps.keys.contains(path) else { continue }
            fresh.append(path)
        }
        let others = installed.filter { claimant in
            !apps.contains { $0.bundleID != nil && $0.bundleID?.lowercased() == claimant.bundleID?.lowercased() }
        }

        var linked: [RecordedItem] = []
        var unclaimed: [RecordedItem] = []
        var otherApps: [String: Int] = [:]
        for path in fresh.sorted() {
            let name = (path as NSString).lastPathComponent
            if let (app, why) = link(name, to: apps) {
                linked.append(RecordedItem(path: path, why: why, app: app.path))
            } else if let owner = others.first(where: { matchesName(name, of: $0.bundleID, names: $0.names) }) {
                otherApps[owner.name, default: 0] += 1
            } else {
                unclaimed.append(RecordedItem(path: path, why: "Appeared while recording", app: nil))
            }
        }
        for key in after.backgroundItems.keys.sorted() where before.backgroundItems[key] == nil {
            guard let mark = after.backgroundItems[key] else { continue }
            let item = mark.path ?? mark.label
            if let app = apps.first(where: { registered(mark, by: $0) }) {
                linked.append(RecordedItem(path: item, why: "Registered to run in the background",
                                           app: app.path, isRegistration: true))
            } else {
                unclaimed.append(RecordedItem(path: item, why: "Registered while recording", app: nil,
                                              isRegistration: true))
            }
        }
        return InstallRecordingResult(
            startedAt: before.takenAt, endedAt: after.takenAt, apps: apps, linked: linked, unclaimed: unclaimed,
            otherApps: otherApps, unreadable: Array(Set(before.unreadable + after.unreadable)).sorted()
        )
    }

    /// Applications that appeared, and those whose version changed.
    static func recordedApps(before: InstallSnapshot, after: InstallSnapshot) -> [RecordedApp] {
        after.apps.keys.sorted().compactMap { path in
            guard let mark = after.apps[path] else { return nil }
            let earlier = before.apps[path]
            guard earlier == nil || earlier?.version != mark.version else { return nil }
            return RecordedApp(
                name: (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                bundleID: mark.identifier, path: path, version: mark.version, wasUpdated: earlier != nil,
                names: mark.names
            )
        }
    }

    /// Named for an app, or from its developer. New apps before updated
    /// ones, so an app that happened to update itself while recording
    /// does not take what the new one made.
    static func link(_ name: String, to apps: [RecordedApp]) -> (RecordedApp, String)? {
        let ordered = apps.filter { !$0.wasUpdated } + apps.filter(\.wasUpdated)
        if let app = ordered.first(where: { matchesName(name, of: $0.bundleID, names: $0.names) }) {
            return (app, "Named for \(app.name)")
        }
        let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for app in ordered {
            guard let vendor = vendor(of: app.bundleID) else { continue }
            // `com.vendorco.updater.plist`, or a folder named for the
            // developer itself: `Application Support/VendorCo`.
            let label = String(vendor.split(separator: ".").last ?? "")
            if lower.hasPrefix(vendor + ".") || (label.count >= 4 && NameKey.of(name) == NameKey.of(label)) {
                return (app, "From the developer of \(app.name)")
            }
        }
        return nil
    }

    /// The identifier, or a name the app answers to, compared the way the
    /// rest of Brim compares names (`NameKey`).
    static func matchesName(_ name: String, of bundleID: String?, names: [String]) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let identifier = bundleID?.lowercased(), !identifier.isEmpty {
            if lower == identifier {
                return true
            }
            for separator in [".", "-", "_"] where lower.hasPrefix(identifier + separator) {
                return true
            }
        }
        let stem = (lower as NSString).deletingPathExtension
        let key = NameKey.of(stem)
        guard key.count >= 3 else { return false }
        return names.contains { NameKey.of($0) == key }
    }

    /// The first two labels of an identifier, the developer's namespace.
    /// Apple's is everyone's, and a code host's is every project it hosts,
    /// so neither says who made something.
    static func vendor(of bundleID: String?) -> String? {
        guard let labels = bundleID?.lowercased().split(separator: "."), labels.count >= 3 else { return nil }
        let vendor = labels.prefix(2).joined(separator: ".")
        let shared: Set = ["com.apple", "io.github", "com.github", "org.gitlab", "io.gitlab", "net.sourceforge",
                           "com.electron", "org.example", "com.example"]
        return shared.contains(vendor) ? nil : vendor
    }

    static func registered(_ mark: InstallSnapshot.BackgroundMark, by app: RecordedApp) -> Bool {
        if let path = mark.path, path == app.path || path.hasPrefix(app.path + "/") {
            return true
        }
        guard let identifier = app.bundleID?.lowercased(), let owner = mark.bundleIdentifier?.lowercased() else {
            return false
        }
        return owner == identifier || owner.hasPrefix(identifier + ".")
    }
}
