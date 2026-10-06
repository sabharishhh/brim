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

    /// The developer and the product, when no record gives a real name.
    /// The product label alone read as "Accmac", "Ccd" and "Chat", which
    /// says nothing about whose it is; `com.adobe.accmac` is "Adobe accmac".
    public static func displayName(for key: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return parts.last.map(\.capitalized) ?? key }
        return parts[parts.count - 2].capitalized + " " + parts[parts.count - 1]
    }

    /// Namespaces shared by everyone who uses them: Apple's, and a code
    /// host's, which is every project it hosts. Neither names a developer.
    public static let sharedVendors: Set<String> = [
        "com.apple", "io.github", "com.github", "org.gitlab", "io.gitlab", "net.sourceforge", "com.electron",
        "org.example", "com.example"
    ]

    /// The developer's own namespace, the first two labels, when a name is
    /// reverse DNS under a common root and the namespace is one developer's.
    public static func vendor(for fileName: String) -> String? {
        guard let key = key(for: fileName) else { return nil }
        let parts = key.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "dev", "app"].contains(String(parts[0])) else {
            return nil
        }
        let vendor = parts.prefix(2).joined(separator: ".")
        return sharedVendors.contains(vendor) ? nil : vendor
    }

    /// The developer's name from its namespace: `com.adobe` is "Adobe".
    public static func vendorDisplayName(_ vendor: String) -> String {
        vendor.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? vendor
    }
}
