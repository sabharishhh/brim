import Foundation

/// What an install script's text visibly does, line by line.
///
/// Read, never run, and never judged. A script can do anything its text
/// does not show, so this names the lines that call something a person
/// would want to know about, in words a person knows, and says nothing
/// about whether calling it is good or bad. Comment lines and the bodies
/// of here-documents are skipped: a script that explains it no longer runs
/// `kextload` does not load a kernel extension, and a property list written
/// out by `cat` is data, not commands.
public enum InstallScriptReading {
    /// One line that does something, with Brim's own words for it.
    public struct Finding: Sendable, Equatable, Hashable {
        /// One-based, as an editor counts.
        public let line: Int
        /// The line as written, trimmed and kept short.
        public let code: String
        public let phrase: String

        public init(line: Int, code: String, phrase: String) {
            self.line = line
            self.code = code
            self.phrase = phrase
        }
    }

    /// What a line must contain, the phrase for it, in the order a person
    /// would want to read them: what runs, what changes the system, then
    /// the rest. A line takes the first rule it meets.
    private struct Rule: Sendable {
        let phrase: String
        let matches: @Sendable (Set<String>, String) -> Bool

        init(_ phrase: String, words: [String]) {
            self.phrase = phrase
            matches = { tokens, _ in words.contains(where: tokens.contains) }
        }

        init(_ phrase: String, all words: [String]) {
            self.phrase = phrase
            matches = { tokens, _ in words.allSatisfy(tokens.contains) }
        }

        init(_ phrase: String, pattern: String) {
            self.phrase = phrase
            matches = { _, line in line.range(of: pattern, options: .regularExpression) != nil }
        }
    }

    static let settingsPhrase = "Changes settings"

    private static let rules: [Rule] = [
        Rule("Starts or stops background jobs", words: ["launchctl"]),
        // Copying or writing a file where launchd and helpers live installs
        // one, whether or not the script also starts it.
        Rule("Installs a background service", pattern:
            #"(\b(cp|mv|ditto|install|ln|tee)\b|>).*/Library/(LaunchDaemons|LaunchAgents|PrivilegedHelperTools)"#),
        Rule("Loads a kernel extension", words: ["kextload", "kmutil"]),
        Rule("Changes system extensions", words: ["systemextensionsctl"]),
        Rule("Changes login items", words: ["sfltool"]),
        Rule("Changes login items", all: ["login", "item"]),
        Rule("Resets privacy permissions", words: ["tccutil"]),
        Rule("Changes Gatekeeper settings", words: ["spctl"]),
        Rule("Trusts a certificate", words: ["add-trusted-cert", "add-certificates", "trust-settings-import"]),
        Rule("Installs a configuration profile", all: ["profiles", "install"]),
        Rule("Changes file attributes, such as quarantine", words: ["xattr"]),
        Rule("Downloads files", words: ["curl", "wget"]),
        Rule("Runs AppleScript", words: ["osascript"]),
        Rule("Quits running programs", words: ["killall", "pkill"]),
        Rule("Changes users or groups", words: ["dscl", "sysadminctl"]),
        Rule("Changes file ownership or permissions", words: ["chown", "chmod"]),
        Rule("Deletes files", words: ["rm", "srm"]),
        Rule("Schedules a task", words: ["crontab"]),
        // "defaults" is an ordinary word; the command is followed by what
        // it does.
        Rule(settingsPhrase, pattern: #"\bdefaults\s+(write|delete|import)\b"#)
    ]

    /// Every line that does something Brim names, in script order.
    public static func findings(in text: String) -> [Finding] {
        var found: [Finding] = []
        var hereDocument: String?
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = hereDocument {
                if trimmed == end {
                    hereDocument = nil
                }
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            hereDocument = hereDocumentEnd(in: trimmed)
            // Words of letters, digits and dashes; a path's last part is a
            // word too, so `/bin/launchctl` counts as `launchctl`.
            let tokens = Set(trimmed.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                .map { $0.lowercased() })
            guard let rule = rules.first(where: { $0.matches(tokens, trimmed) }) else { continue }
            let code = trimmed.count > 200 ? String(trimmed.prefix(199)) + "…" : trimmed
            found.append(Finding(line: index + 1, code: code, phrase: rule.phrase))
        }
        return found
    }

    /// The phrases a script's findings come to, each once, in the order
    /// of the rules, with settings last.
    public static func calls(in text: String) -> [String] {
        let phrases = Set(findings(in: text).map(\.phrase))
        var ordered: [String] = []
        for rule in rules where phrases.contains(rule.phrase) && !ordered.contains(rule.phrase)
            && rule.phrase != settingsPhrase
        {
            ordered.append(rule.phrase)
        }
        if phrases.contains(settingsPhrase) {
            ordered.append(settingsPhrase)
        }
        return ordered
    }

    /// The word that ends a here-document started on this line, if one is.
    static func hereDocumentEnd(in line: String) -> String? {
        guard let match = line.firstMatch(of: /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/) else { return nil }
        return String(match.1)
    }

    /// A script that is not text, such as a compiled program, cannot be
    /// read this way, and the preview says so.
    public static func isText(_ data: Data) -> Bool {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        return true
    }
}
