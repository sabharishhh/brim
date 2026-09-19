import Foundation
import Security

/// Resolves various artifacts (bundles, plists, receipts) into a canonical `Identity`.
public actor IdentityResolver {
    public let root: FileSystemRoot
    private var cache: [URL: Identity] = [:]
    
    public init(root: FileSystemRoot) {
        self.root = root
    }
    
    public func resolve(bundleURL: URL) -> Identity {
        if let cached = cache[bundleURL] { return cached }
        
        let name = bundleURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: bundleURL)
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        
        var teamID: String? = nil
        var cdHashString: String? = nil
        var isSandboxed = false
        var groupContainers: [String] = []
        
        // Use SecStaticCode to extract signing info
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode {
            var signInfo: CFDictionary?
            // kSecCSRequirementInformation flag gets entitlements
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &signInfo) == errSecSuccess {
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
        
        let identity = Identity(
            bundleID: bundleID,
            teamID: teamID,
            name: name,
            version: version,
            isSandboxed: isSandboxed,
            groupContainers: groupContainers,
            cdHash: cdHashString
        )
        cache[bundleURL] = identity
        return identity
    }
    
    public func resolve(launchdPlistURL: URL) -> Identity {
        if let cached = cache[launchdPlistURL] { return cached }
        
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
        
        let identity = Identity(name: name, launchdLabel: label, launchdProgramPath: programPath)
        cache[launchdPlistURL] = identity
        return identity
    }
    
    public func resolve(receiptURL: URL) -> Identity {
        if let cached = cache[receiptURL] { return cached }
        
        let name = receiptURL.deletingPathExtension().lastPathComponent
        let identity = Identity(name: name, packageIdentifier: name)
        cache[receiptURL] = identity
        return identity
    }
}
