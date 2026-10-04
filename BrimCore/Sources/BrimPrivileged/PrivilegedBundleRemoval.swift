import Foundation
import Security

/// The helper's rules for an installed bundle that belongs to root.
///
/// An installer package runs as root, so what it installs is root's:
/// Microsoft Teams in `/Applications` is `root:wheel` and read-only to its
/// own user, and so is the audio driver its installer puts in
/// `/Library/Audio/Plug-Ins/HAL`. Finder asks for an administrator to move
/// either. Brim had no way to, so its review said the application "stays
/// where it is" and the uninstall removed a container and nothing else.
///
/// Like the job and link rules, this decides from what it can see and
/// takes nothing on trust: a place installers put bundles, a plain name
/// with the extension that place holds, a real folder rather than a link,
/// and a bundle that is not Apple's and not Brim. It never deletes. The
/// bundle is set aside where an administrator can still reach it.
public enum PrivilegedBundleRemoval {
    public enum Domain: String, Sendable, CaseIterable {
        case applications
        case halPlugIns
        case audioComponents
        case vstPlugIns
        case vst3PlugIns

        public var directory: String {
            switch self {
            case .applications: "/Applications"
            case .halPlugIns: "/Library/Audio/Plug-Ins/HAL"
            case .audioComponents: "/Library/Audio/Plug-Ins/Components"
            case .vstPlugIns: "/Library/Audio/Plug-Ins/VST"
            case .vst3PlugIns: "/Library/Audio/Plug-Ins/VST3"
            }
        }

        /// What a bundle in this place is called. Anything else there is
        /// not an installed bundle, whatever it is.
        public var extensions: Set<String> {
            switch self {
            case .applications: ["app"]
            case .halPlugIns: ["driver", "plugin"]
            case .audioComponents: ["component"]
            case .vstPlugIns: ["vst"]
            case .vst3PlugIns: ["vst3"]
            }
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case unknownDomain(String)
        case notAPlainName(String)
        case notThatKindOfBundle(String)
        case notThere
        case notAFolder
        case belongsToApple(String)
        case isBrim
        case couldNotQuarantine(String)

        public var explanation: String {
            switch self {
            case let .unknownDomain(domain):
                "\(domain) is not a place this can touch."
            case let .notAPlainName(name):
                "\(name) is not a plain file name."
            case let .notThatKindOfBundle(name):
                "\(name) is not the kind of bundle that is installed there."
            case .notThere:
                "It is not there any more."
            case .notAFolder:
                "That is a link or a file, not an installed bundle."
            case let .belongsToApple(name):
                "\(name) is part of macOS."
            case .isBrim:
                "That is Brim itself."
            case let .couldNotQuarantine(why):
                "It could not be set aside: \(why)"
            }
        }
    }

    public static func target(domain: String, name: String) throws -> URL {
        guard let domain = Domain(rawValue: domain) else { throw Refusal.unknownDomain(domain) }
        guard PrivilegedJobRemoval.isPlainName(name) else { throw Refusal.notAPlainName(name) }
        let ext = (name as NSString).pathExtension.lowercased()
        guard domain.extensions.contains(ext) else { throw Refusal.notThatKindOfBundle(name) }
        return URL(fileURLWithPath: domain.directory).appendingPathComponent(name)
    }

    /// Whose the bundle is, read from the bundle. Its identifier, and for
    /// anything that says it is not Apple's, its signature as well: an
    /// identifier is a string anybody can write.
    public static func check(bundle: URL) throws {
        let name = bundle.lastPathComponent
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let identifier = (info?["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
        if identifier.hasPrefix("com.apple.") {
            throw Refusal.belongsToApple(name)
        }
        if identifier.hasPrefix("com.sabharishhh.brim") {
            throw Refusal.isBrim
        }
        if isSignedByApple(bundle) {
            throw Refusal.belongsToApple(name)
        }
    }

    static func isSignedByApple(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
