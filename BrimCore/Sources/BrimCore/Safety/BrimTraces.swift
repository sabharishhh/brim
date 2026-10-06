import Foundation

/// Everything Brim writes into the person's account, and the script that
/// deletes it once Brim has quit.
///
/// Removing Brim through its own uninstall path sent its files to the Trash,
/// where they stayed, and wrote a plan and a journal for the removal into the
/// folder being removed. An uninstaller for an app whose purpose is leaving
/// nothing behind cannot leave its own records in the Trash. So Brim removes
/// itself by deleting, after it has quit: a running app writes its settings
/// back as it exits, and `cfprefsd` would restore a deleted preferences file.
public enum BrimTraces {
    /// Places where Brim's identifiers name what it wrote.
    static let identifierDomains: [FileSystemRoot.Domain] = [
        .userApplicationSupport, .userCaches, .userHTTPStorages, .userWebKit, .userCookies,
        .userSavedApplicationState, .userLogs, .userPreferences, .userPreferencesByHost,
        .userApplicationScripts, .userAutosaveInformation, .darwinUserCache, .darwinUserTemp
    ]

    /// Every path Brim left in the person's account: anything named for one
    /// of its identifiers or inside one, its support folder, its record of
    /// recent documents and its crash reports. Containers are left out:
    /// macOS keeps them as data vaults nobody but Finder can delete, and Brim
    /// is not sandboxed, so the only ones carrying its name came from tests.
    public static func paths(
        in root: FileSystemRoot, identifiers: [String], fileManager: FileManager = .default
    ) -> [URL] {
        var found: [URL] = []
        func add(_ url: URL) {
            var info = stat()
            if lstat(url.path, &info) == 0, !found.contains(url) {
                found.append(url)
            }
        }
        add(root.url(for: .userApplicationSupport).appendingPathComponent("Brim"))
        let lowered = identifiers.map { $0.lowercased() }
        for domain in identifierDomains {
            let directory = root.url(for: domain)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() {
                let entry = name.lowercased()
                if lowered.contains(where: { entry == $0 || entry.hasPrefix($0 + ".") }) {
                    add(directory.appendingPathComponent(name))
                }
            }
        }
        for identifier in identifiers {
            add(root.url(for: .userRecentDocuments).appendingPathComponent("\(identifier).sfl4"))
        }
        let reports = root.url(for: .userDiagnosticReports)
        let reportNames = ((try? fileManager.contentsOfDirectory(atPath: reports.path)) ?? []).sorted()
        for name in reportNames where isBrimsReport(name) {
            add(reports.appendingPathComponent(name))
        }
        return found
    }

    static func isBrimsReport(_ name: String) -> Bool {
        ["brim", "BrimJobHelper"].contains { LocationInventory.Location.isReport(name, of: $0) }
    }

    /// A shell script that waits for Brim to quit, then clears its preference
    /// domains through `cfprefsd`, deletes every path, retracts the
    /// application's Launch Services record and deletes itself.
    ///
    /// It waits by reading its standard input to the end. Brim holds the other
    /// end of that pipe, and the kernel closes it when Brim's process ends,
    /// whatever ends it. No process identifier is involved, which could be
    /// reused by something else while the script waited.
    public static func removalScript(
        paths: [URL], preferenceDomains: [String], unregistering bundle: URL?
    ) -> String {
        var lines = [
            "#!/bin/sh",
            "/bin/cat > /dev/null"
        ]
        lines += preferenceDomains.map { "/usr/bin/defaults delete \(quoted($0)) 2>/dev/null" }
        lines += paths.map { "/bin/rm -rf -- \(quoted($0.path))" }
        if let bundle {
            lines.append("\(quoted(lsregister)) -u \(quoted(bundle.path)) 2>/dev/null")
        }
        lines.append("/bin/rm -f -- \"$0\"")
        return lines.joined(separator: "\n") + "\n"
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
