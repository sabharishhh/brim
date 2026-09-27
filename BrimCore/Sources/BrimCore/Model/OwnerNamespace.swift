import Foundation

/// Groups file names that share an application namespace without treating a
/// vendor's entire reverse-DNS domain as one removable application.
public enum OwnerNamespace {
    public static func key(for fileName: String) -> String? {
        let originalParts = fileName.split(separator: ".")
        let hasTeamPrefix = originalParts.first.map {
            $0.count == 10 && $0.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        } ?? false
        var name = fileName.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.hasPrefix("group.") {
            name = String(name.dropFirst(6))
        }

        var parts = name.split(separator: ".").map(String.init)
        if hasTeamPrefix, parts.count > 2 {
            parts.removeFirst()
        }
        guard parts.count >= 2, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }

        let commonRoots: Set = ["com", "org", "net", "io", "dev", "app", "edu", "gov"]
        let countryRoot = parts[0].count == 2 && parts[0].allSatisfy(\.isLetter)
        guard commonRoots.contains(parts[0]) || countryRoot else { return nil }
        let depth = if commonRoots.contains(parts[0]) {
            min(3, parts.count)
        } else if parts.count >= 4, parts[1] == "co" {
            4
        } else {
            2
        }
        return parts.prefix(depth).joined(separator: ".")
    }

    public static func displayName(for key: String) -> String {
        key.split(separator: ".").last.map { String($0).capitalized } ?? key
    }

    /// The vendor portion is for a list heading only. It must never become
    /// a removal identity because one vendor can ship unrelated apps.
    public static func vendorKey(for fileName: String) -> String? {
        guard let key = key(for: fileName) else { return nil }
        let parts = key.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        if parts[0] == "jp", parts[1] == "co", parts.count >= 4 {
            return parts.prefix(3).joined(separator: ".")
        }
        return parts.prefix(2).joined(separator: ".")
    }
}
