import BrimCore
import CryptoKit
import Foundation

/// The folders crash reporting frameworks keep for an application inside
/// their own cache folder, which nothing in the application's name or
/// identifier leads to.
///
/// eqMac ships Sentry, and after its removal two of Sentry's folders were
/// still on the disk: `Caches/SentryCrash/eqMac`, named with the bundle
/// name, and `Caches/io.sentry/a456d41a…`, named with the SHA-1 of the
/// address eqMac sends its reports to. Each counts only because the
/// bundle ships the framework that writes it, and the second only when
/// that address is in the application's own executable and hashes to the
/// folder's name exactly.
struct CrashReporterFolders {
    /// Frameworks that name an application's folder with its bundle name.
    static let byBundleName = [
        "SentryCrash": (framework: "Sentry.framework", product: "Sentry"),
        "KSCrash": (framework: "KSCrash.framework", product: "KSCrash")
    ]

    private let identity: Identity
    private let named: [String: String]
    private let sentryFolders: Set<String>

    init(identity: Identity) {
        self.identity = identity
        let components = identity.identitySurface?.components ?? []
        let shipped = Set(components.map { ($0.path as NSString).lastPathComponent })
        named = Self.byBundleName.filter { shipped.contains($0.value.framework) }.mapValues(\.product)
        sentryFolders = shipped.contains("Sentry.framework")
            ? Set(Self.executable(of: identity).map(Self.sentryAddresses).map { $0.map(Self.sha1) } ?? [])
            : []
    }

    /// What this application has in one of the frameworks' folders, or nil
    /// when the folder is not one of theirs.
    func evidence(in parent: URL, search: inout DirectorySearch) -> [Evidence]? {
        let folder = parent.lastPathComponent
        if let product = named[folder] {
            let names = Set([identity.bundleName, identity.name].compactMap(\.self).filter { !$0.isEmpty })
            return search.entries(parent).filter(names.contains).map {
                evidence(parent.appendingPathComponent($0),
                         "Crash reports \(product) keeps for \(identity.name), which ships it.")
            }
        }
        if folder == "io.sentry", !sentryFolders.isEmpty {
            return search.entries(parent).filter { sentryFolders.contains($0.lowercased()) }.map {
                evidence(parent.appendingPathComponent($0),
                         "Reports Sentry keeps for \(identity.name), named for the address in its app.")
            }
        }
        return nil
    }

    private func evidence(_ url: URL, _ sentence: String) -> Evidence {
        Evidence(url: url, tier: .B, mechanism: "NestedFolderSource", humanSentence: sentence)
    }

    private static func executable(of identity: Identity) -> URL? {
        guard let bundle = identity.bundlePath else { return nil }
        let main = identity.identitySurface?.components.first { $0.path == bundle }
        guard let name = main?.executableName ?? identity.identitySurface?.components.first?.executableName
        else { return nil }
        return URL(fileURLWithPath: bundle).appendingPathComponent("Contents/MacOS/\(name)")
    }

    /// Sentry addresses written into an executable, read without loading
    /// it. Anything over 256 MB is not read.
    static func sentryAddresses(in executable: URL) -> [String] {
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped),
              data.count <= 256 << 20,
              let text = String(data: data, encoding: .isoLatin1) else { return [] }
        return sentryAddresses(in: text)
    }

    static func sentryAddresses(in text: String) -> [String] {
        let pattern = #"https://[0-9a-f]{32}(?::[0-9a-f]{32})?@[A-Za-z0-9.\-]+(?::[0-9]+)?/[0-9]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Array(Set(expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }))
    }

    static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
