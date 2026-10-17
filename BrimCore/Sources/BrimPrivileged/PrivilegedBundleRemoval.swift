import Foundation
import Security

/// The rules for an installed bundle that belongs to root, as anything an
/// installer package installs does. Decided from what can be seen, nothing
/// on trust: a place installers put bundles, a plain name with that place's
/// extension, a real folder rather than a link, and a bundle that is not
/// Apple's and not Brim. It never deletes; the bundle is set aside where an
/// administrator can still reach it.
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

        /// What a bundle in this place is called; anything else there is not an
        /// installed bundle.
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

    /// Whose the bundle is, read from the bundle: its identifier and, for
    /// anything claiming not to be Apple's, its signature too, since an
    /// identifier is a string anyone can write.
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
