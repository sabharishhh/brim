import Foundation

/// Everything Brim writes into the person's account, and the script that
/// deletes it once Brim has quit. Brim removes itself by deleting, not by
/// the Trash, and only after quitting: a running app writes its settings
/// back as it exits, and `cfprefsd` would restore a deleted preferences
/// file.
public enum BrimTraces {
    /// Places where Brim's identifiers name what it wrote.
    static let identifierDomains: [FileSystemRoot.Domain] = [
        .userApplicationSupport, .userCaches, .userHTTPStorages, .userWebKit, .userCookies,
        .userSavedApplicationState, .userLogs, .userPreferences, .userPreferencesByHost,
        .userApplicationScripts, .userAutosaveInformation, .darwinUserCache, .darwinUserTemp
    ]

    /// Every path Brim left in the person's account: anything named for one of
    /// its identifiers, its support folder, its recent-documents record and its
    /// crash reports. Not containers: macOS keeps them as data vaults only
    /// Finder can delete, and Brim is not sandboxed.
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

    /// Reports are named for the process. Brim's executable was `brim`
    /// until 1.0 named the app `Brim.app`.
    static func isBrimsReport(_ name: String) -> Bool {
        ["Brim", "brim", "BrimJobHelper"].contains { LocationInventory.Location.isReport(name, of: $0) }
    }

    /// A shell script that waits for Brim to quit, clears its preference
    /// domains through `cfprefsd`, deletes every path, retracts Brim's Launch
    /// Services record and deletes itself. It waits by reading standard input
    /// to the end: the kernel closes Brim's end of the pipe when Brim exits. No
    /// process identifier, which could be reused while it waits.
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
