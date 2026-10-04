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

    /// The folder in the home folder an Electron editor says it keeps its
    /// data in. Every editor built from Visual Studio Code carries a
    /// `product.json` naming it: `.vscode`, `.cursor`, `.antigravity-ide`.
    /// Nothing about the application's name predicts `.vscode` or the
    /// `-ide` suffix, and Antigravity's 400 MB of extensions outlived its
    /// removal because of it. The bundle's own declaration is a record, so
    /// it is trusted where a name alone is not.
    static func declaredHomeFolders(of bundle: URL) -> [String] {
        let product = bundle.appendingPathComponent("Contents/Resources/app/product.json")
        guard let data = try? Data(contentsOf: product), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = json["dataFolderName"] as? String,
              folder.hasPrefix("."), folder.count > 2, IdentitySurface.isPathComponent(folder)
        else { return [] }
        return [folder]
    }
}
