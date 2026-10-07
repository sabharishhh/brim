import Foundation

/// Release notes as a developer publishes them, made ready to read.
///
/// Feeds often repeat every earlier version under the newest one: one
/// app's notes for 2.7.2 were three lines about 2.7.2 and forty about 2.7.1
/// and 2.7, and a summary of the whole text described 2.7. So the notes are
/// cut at the first heading for an older version before anything reads
/// them.
public enum ReleaseNotesText {
    /// Notes this short are shown as written; nothing is gained by
    /// condensing them.
    public static let shortWordLimit = 12

    /// The part of `notes` about `version`: from that version's heading,
    /// if the notes open with one, to the heading of an earlier version.
    ///
    /// Versions are compared whole, pre-release included: a later mention
    /// of `v2.8-rc.0` is not 2.8-rc.1's heading, and keeping only what
    /// followed it kept 540 characters of 8,743, all of them a changelog.
    public static func section(of notes: String, version: String) -> String {
        let target = normalised(version)
        let headings = versionHeadings(in: notes)
        let opening = notes.index(notes.startIndex, offsetBy: 200, limitedBy: notes.endIndex) ?? notes.endIndex
        let start = headings.first { $0.version == target && $0.range.lowerBound < opening }?.range.lowerBound
            ?? notes.startIndex
        let end = headings.first { heading in
            heading.range.lowerBound > start && heading.version != target
                && !isNewer(components(of: heading.version), than: components(of: target))
        }?.range.lowerBound ?? notes.endIndex
        return tidy(String(notes[start ..< end]))
    }

    public static func isShort(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count <= shortWordLimit
    }

    /// A CVE identifier is a security fix whatever else the notes say.
    public static func mentionsCVE(_ text: String) -> Bool {
        text.firstMatch(of: /CVE-\d{4}-\d{4,}/) != nil
    }

    /// One line, single spaces.
    public static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Versions

    struct Heading {
        let version: String
        let range: Range<String.Index>
    }

    /// Versions written the way a heading writes them: `v2.7.1`, or after
    /// the word version or release, or first on a line. A version anywhere
    /// else ("Requires macOS 14.0") is not a heading, and neither is a
    /// changelog link ("Compare v2.7 → v2.7.1").
    static func versionHeadings(in notes: String) -> [Heading] {
        let number = #"(\d+(?:\.\d+){1,3}(?:[-.]?(?:rc|beta|alpha|b|a)[.-]?\d*)?)"#
        let pattern = "(?i)(?:^|\\n)[^\\S\\n]*[#*\\-•\\p{So}\\s]*v?" + number
            + "|\\b(?:version|release)\\s+v?" + number + "|\\bv" + number
        guard let regex = try? Regex(pattern) else { return [] }
        var headings: [Heading] = []
        for match in notes.matches(of: regex) {
            var version: Substring?
            for index in 1 ..< match.output.count where version == nil {
                version = match.output[index].substring
            }
            guard let version else { continue }
            let from = notes.index(match.range.lowerBound, offsetBy: -14, limitedBy: notes.startIndex)
                ?? notes.startIndex
            let before = notes[from ..< match.range.lowerBound].lowercased()
            if before.contains("compare") || before.contains("→") || before.contains("...") {
                continue
            }
            headings.append(Heading(version: normalised(String(version)), range: match.range))
        }
        return headings
    }

    static func normalised(_ version: String) -> String {
        version.lowercased().drop { !$0.isNumber }.trimmingCharacters(in: .whitespaces)
    }

    static func components(of version: String) -> [Int] {
        let digits = version.drop { !$0.isNumber }
        return digits.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return false
    }
}
