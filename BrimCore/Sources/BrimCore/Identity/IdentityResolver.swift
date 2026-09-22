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
        if let entry = cache[bundleURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL { return entry.identity }
        let identity = await Task.detached {
            self.parseBundle(bundleURL)
        }.value
        cache[bundleURL] = CacheEntry(identity: identity, timestamp: Date())
        return identity
    }
    
    public func resolve(launchdPlistURL: URL) async -> Identity {
        if let entry = cache[launchdPlistURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL { return entry.identity }
        let identity = await Task.detached {
            self.parseLaunchd(launchdPlistURL)
        }.value
        cache[launchdPlistURL] = CacheEntry(identity: identity, timestamp: Date())
        return identity
    }
    
    public func resolve(receiptURL: URL) async -> Identity {
        if let entry = cache[receiptURL], Date().timeIntervalSince(entry.timestamp) < cacheTTL { return entry.identity }
        let identity = await Task.detached {
            self.parseReceipt(receiptURL)
        }.value
        cache[receiptURL] = CacheEntry(identity: identity, timestamp: Date())
        return identity
    }
    
    // MARK: - Offloaded Blocking Parsing
    
    nonisolated private func parseBundle(_ bundleURL: URL) -> Identity {
        // Enforce boundary check
        let realPath = (try? bundleURL.resolvingSymlinksInPath().path) ?? bundleURL.path
        guard realPath.hasPrefix(root.rootURL.path) else {
            return Identity(name: "Out of bounds")
        }
        
        let name = bundleURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: bundleURL)
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        // The name the bundle uses for itself, which is what it names its
        // support and cache folders after and is not always its file name.
        let declaredName = (bundle?.infoDictionary?["CFBundleName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        
        var teamID: String? = nil
        var cdHashString: String? = nil
        var isSandboxed = false
        var groupContainers: [String] = []
        
        // Two flags, and asking for one of them was a silent hole. The
        // team identifier is signing information and the entitlements are
        // requirement information, so a call that asks only for the latter
        // reports a sandbox and group containers correctly while leaving
        // `teamID` nil for every application on the machine. Nothing threw
        // and nothing was logged: `TeamIDSource` opens by returning an
        // empty array when there is no team, so the whole of it, and every
        // team-prefixed rule in the inventory, read as "nothing found"
        // rather than "never asked". `CodeSignature` in `BrimScan` had the
        // flags right all along, which is the two-readings-of-one-fact
        // hazard again.
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
            cdHash: cdHashString
        )
    }
    
    nonisolated private func parseLaunchd(_ launchdPlistURL: URL) -> Identity {
        let name = launchdPlistURL.deletingPathExtension().lastPathComponent
        var label: String? = nil
        var programPath: String? = nil
        
        if let data = try? Data(contentsOf: launchdPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            label = plist["Label"] as? String
            
            if let path = plist["Program"] as? String {
                programPath = path
            } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                programPath = first
            }
        }
        
        return Identity(name: name, launchdLabel: label, launchdProgramPath: programPath)
    }
    
    nonisolated private func parseReceipt(_ receiptURL: URL) -> Identity {
        let name = receiptURL.deletingPathExtension().lastPathComponent
        return Identity(name: name, packageIdentifier: name)
    }
}
