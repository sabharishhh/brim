import Foundation

/// How an application came to be on this Mac.
public enum ApplicationSource: String, Codable, Sendable, CaseIterable {
    case apple
    case appStore
    case homebrew
    case setapp
    case direct

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .setapp: "Setapp"
        case .direct: "Downloaded"
        }
    }
}

/// The facts about an application that are read from its bundle and
/// Spotlight rather than from Brim's own history, and the rules that turn
/// raw values into something a person reads.
public enum ApplicationFacts {
    /// Apple's own applications, whether they came with macOS or from the
    /// App Store. Apple signs these, so the identifier is the claim.
    public static func isApple(bundleID: String?) -> Bool {
        bundleID?.hasPrefix("com.apple.") ?? false
    }

    /// The first match wins: Apple before the App Store, because Pages
    /// from the App Store is still Apple's, and Homebrew before a plain
    /// download, because the cask is how it will be updated and removed.
    public static func source(
        bundleID: String?, path: String, hasAppStoreReceipt: Bool, isHomebrewCask: Bool
    ) -> ApplicationSource {
        if isApple(bundleID: bundleID) {
            return .apple
        }
        if hasAppStoreReceipt {
            return .appStore
        }
        if isHomebrewCask {
            return .homebrew
        }
        if path.contains("/Setapp/") || (bundleID?.hasSuffix("-setapp") ?? false) {
            return .setapp
        }
        return .direct
    }

    /// The organisation in a signing certificate's summary.
    ///
    /// "Developer ID Application: Adobe Inc. (JQ525L2MZD)" is "Adobe Inc.".
    /// An App Store app is re-signed by Apple, so its summary names Apple's
    /// signing service rather than the developer, and gives nothing here.
    public static func organisation(fromCertificateSummary summary: String) -> String? {
        // Only Developer ID: a development certificate names a person or
        // an email address, which is nobody's idea of a developer's name.
        guard summary.hasPrefix("Developer ID Application: ") else { return nil }
        var name = summary[summary.index(after: summary.firstIndex(of: ":")!)...]
            .trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    /// A developer name when the certificate gives none: the vendor part
    /// of the identifier, `com.microsoft.Word` as "Microsoft".
    public static func vendor(fromBundleID bundleID: String?) -> String? {
        guard let parts = bundleID?.split(separator: "."), parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        guard vendor.count > 1 else { return nil }
        return vendor.prefix(1).uppercased() + vendor.dropFirst()
    }

    /// `public.app-category.graphics-design` as "Graphics & Design".
    public static func categoryTitle(_ identifier: String) -> String {
        let key = identifier.replacingOccurrences(of: "public.app-category.", with: "")
        if key.hasSuffix("-games") || key == "games" {
            return "Games"
        }
        let named = [
            "graphics-design": "Graphics & Design",
            "healthcare-fitness": "Health & Fitness",
            "developer-tools": "Developer Tools"
        ]
        if let title = named[key] {
            return title
        }
        return key.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
