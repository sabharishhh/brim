import Foundation
import Security

/// Resolves various artifacts (bundles, plists, receipts) into a canonical `Identity`.
public actor IdentityResolver {
    public let root: FileSystemRoot
    private struct CacheEntry {
        let identity: Identity
        let timestamp: Date
    }

    private var cache: [URL: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    public init(root: FileSystemRoot) {
        self.root = root
    }

    public func resolve(bundleURL: URL) async -> Identity {
        if let entry = cache[bundleURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.identity
        }
        let identity = await parseBundle(bundleURL)
        if !Task.isCancelled {
            cache[bundleURL] = CacheEntry(identity: identity, timestamp: Date())
        }
        return identity
    }

    public func resolve(launchdPlistURL: URL) async -> Identity {
        if let entry = cache[launchdPlistURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.identity
        }
        let identity = await parseLaunchd(launchdPlistURL)
        if !Task.isCancelled {
            cache[launchdPlistURL] = CacheEntry(identity: identity, timestamp: Date())
        }
        return identity
    }

    public func resolve(receiptURL: URL) async -> Identity {
        if let entry = cache[receiptURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.identity
        }
        let identity = await parseReceipt(receiptURL)
        if !Task.isCancelled {
            cache[receiptURL] = CacheEntry(identity: identity, timestamp: Date())
        }
        return identity
    }

    // MARK: - Offloaded Blocking Parsing

    @concurrent
    private nonisolated func parseBundle(_ bundleURL: URL) async -> Identity {
        // Enforce boundary check
        let realPath = bundleURL.resolvingSymlinksInPath().path
        let rootPath = root.rootURL.resolvingSymlinksInPath().path
        guard rootPath == "/" || realPath == rootPath || realPath.hasPrefix(rootPath + "/") else {
            return Identity(name: "Out of bounds")
        }

        let name = bundleURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: bundleURL)
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        // The name the bundle uses for itself, which it names its folders after
        // and which is not always its file name.
        let declaredName = (bundle?.infoDictionary?["CFBundleName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        var teamID: String? = nil
        var cdHashString: String? = nil
        var isSandboxed = false
        var groupContainers: [String] = []

        // Both flags: the team identifier is signing information and the
        // entitlements are requirement information. Asking for only the latter
        // leaves `teamID` nil for every app without any error. `CodeSignature` in
        // `BrimScan` reads the same fact, and a test holds the two to one answer.
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode {
            var signInfo: CFDictionary?
            let wanted = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            if SecCodeCopySigningInformation(code, wanted, &signInfo) == errSecSuccess {
                let infoDict = signInfo as? [String: Any]
                teamID = infoDict?[kSecCodeInfoTeamIdentifier as String] as? String

                if let cdHashData = infoDict?[kSecCodeInfoUnique as String] as? Data {
                    cdHashString = cdHashData.map { String(format: "%02x", $0) }.joined()
                }

                if let entitlements = infoDict?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                    isSandboxed = (entitlements["com.apple.security.app-sandbox"] as? Bool) ?? false
                    if let groups = entitlements["com.apple.security.application-groups"] as? [String] {
                        groupContainers = groups
                    }
                }
            }
        }

        return Identity(
            bundleID: bundleID,
            teamID: teamID,
            name: name,
            bundleName: declaredName,
            version: version,
            isSandboxed: isSandboxed,
            groupContainers: groupContainers,
            cdHash: cdHashString,
            bundlePath: bundleURL.path
        )
    }

    @concurrent
    private nonisolated func parseLaunchd(_ launchdPlistURL: URL) async -> Identity {
        let name = launchdPlistURL.deletingPathExtension().lastPathComponent
        var label: String? = nil
        var programPath: String? = nil

        let data = try? Data(contentsOf: launchdPlistURL)
        let raw = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
        if let plist = raw as? [String: Any] {
            label = plist["Label"] as? String

            if let path = plist["Program"] as? String {
                programPath = path
            } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                programPath = first
            }
        }

        return Identity(name: name, launchdLabel: label, launchdProgramPath: programPath)
    }

    @concurrent
    private nonisolated func parseReceipt(_ receiptURL: URL) async -> Identity {
        let name = receiptURL.deletingPathExtension().lastPathComponent
        return Identity(name: name, packageIdentifier: name)
    }
}
