import Foundation

// swiftformat:disable wrapMultilineStatementBraces

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

        /// The same thing in words for someone who has never seen a script.
        public var plain: String {
            InstallScriptReading.plainPhrases[phrase] ?? phrase
        }

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

    /// What each finding means for the person's Mac, without the commands.
    /// The preview leads with these; the technical phrase and the line sit
    /// behind Details.
    static let plainPhrases: [String: String] = [
        "Starts or stops background jobs": "Starts or stops helpers that run in the background",
        "Installs a background service": "Adds a helper that runs in the background",
        "Loads a kernel extension": "Adds code that runs inside macOS itself",
        "Changes system extensions": "Adds or changes a system extension",
        "Changes login items": "Opens something when you log in",
        "Resets privacy permissions": "Resets what apps are allowed to access",
        "Changes Gatekeeper settings": "Changes how your Mac checks downloaded apps",
        "Trusts a certificate": "Tells your Mac to trust its own certificate",
        "Installs a configuration profile": "Installs a profile that can change your Mac's settings",
        "Changes file attributes, such as quarantine": "Removes the warning macOS shows for downloaded files",
        "Downloads files": "Downloads more files from the internet",
        "Runs AppleScript": "Controls other apps",
        "Quits running programs": "Closes or restarts programs that are running",
        "Changes users or groups": "Changes user accounts",
        "Changes file ownership or permissions": "Changes who can open or run some files",
        "Deletes files": "Deletes some files",
        "Schedules a task": "Schedules something to run later",
        settingsPhrase: "Changes settings"
    ]

    /// One thing a script changes, in Brim's technical phrase and in
    /// plain words.
    public struct Consequence: Sendable, Hashable {
        public let phrase: String
        public let plain: String
    }

    /// Each consequence once, in the order of the rules: what runs, what
    /// changes the system, then the rest.
    public static func consequences(of findings: [Finding]) -> [Consequence] {
        let phrases = Set(findings.map(\.phrase))
        var ordered: [Consequence] = []
        // Adding a helper says it runs in the background; starting one
        // as well is the same thing to the person reading.
        let adds = phrases.contains("Installs a background service")
        for rule in rules where phrases.contains(rule.phrase) {
            guard !(adds && rule.phrase == "Starts or stops background jobs") else { continue }
            let plain = plainPhrases[rule.phrase] ?? rule.phrase
            if !ordered.contains(where: { $0.plain == plain }) {
                ordered.append(Consequence(phrase: rule.phrase, plain: plain))
            }
        }
        return ordered
    }

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
            && rule.phrase != settingsPhrase {
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
