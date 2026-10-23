import Foundation
import Security

extension BundleSurfaceReader {
    struct Signature {
        var identifier: String?
        var team: String?
        var entitlements: [String: Any] = [:]
        var gap: String?

        static func read(_ url: URL) -> Signature {
            read(url, validate: true)
        }

        static func read(_ url: URL, validate: Bool) -> Signature {
            var code: SecStaticCode?
            let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            guard created == errSecSuccess, let code else {
                return Signature(gap: created == errSecCSUnsigned ? "Unsigned code." : "Code signature unavailable.")
            }
            var dictionary: CFDictionary?
            let wanted = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            let status = SecCodeCopySigningInformation(code, wanted, &dictionary)
            guard status == errSecSuccess, let values = dictionary as? [String: Any] else {
                return Signature(gap: status == errSecCSUnsigned ? "Unsigned code." : "Code signature unavailable.")
            }
            if !validate {
                return Signature(identifier: values[kSecCodeInfoIdentifier as String] as? String,
                                 team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                                 entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
            }
            let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            // kSecCodeSignatureAdhoc (0x0002) is not exported to Swift.
            let adHocFlag: UInt32 = 0x0002
            if flags & adHocFlag != 0 {
                return Signature(gap: "Ad-hoc signature.")
            }
            let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
            guard valid == errSecSuccess else {
                let reason = valid == errSecCSUnsigned ? "Unsigned code." : "Code signature could not be verified."
                return Signature(gap: reason)
            }
            return Signature(
                identifier: values[kSecCodeInfoIdentifier as String] as? String,
                team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            )
        }
    }

    /// The home folder an Electron editor declares in its `product.json`
    /// (`.vscode`, `.cursor`, `.antigravity-ide`), which the app's name does not
    /// predict. The declaration is a record, but still only a string the bundle
    /// wrote: it is taken only when it names the product, never a shared or
    /// credentials folder such as `.ssh`.
    static func declaredHomeFolders(of bundle: URL) -> [String] {
        let product = bundle.appendingPathComponent("Contents/Resources/app/product.json")
        guard let size = (try? product.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: product),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = json["dataFolderName"] as? String,
              folder.hasPrefix("."), folder.count > 2, IdentitySurface.isPathComponent(folder),
              !SafetyChecker.credentialStores.contains(folder.lowercased()),
              !SafetyChecker.personalFolders.contains(folder.lowercased())
        else { return [] }
        let products = ["applicationName", "nameShort", "nameLong", "urlProtocol"]
            .compactMap { json[$0] as? String }
            .map(NameKey.of).filter { $0.count >= 3 }
        let key = NameKey.of(String(folder.dropFirst()))
        guard products.contains(where: { key.contains($0) || $0.contains(key) }) else { return [] }
        return [folder]
    }
}
