import Foundation
import Security

// swiftformat:disable wrapMultilineStatementBraces
/// Who signed a bundle and what it is entitled to, for a preview.
///
/// Read without validating the whole bundle: a preview reports what the
/// signature claims and leaves the verdict to Gatekeeper, which is asked
/// separately. A signature that cannot be read at all is reported as
/// unsigned rather than guessed at.
public struct CodeFacts: Sendable, Equatable {
    /// The leaf certificate's name: "Developer ID Application: Example Ltd (ABCDE12345)".
    public let signer: String?
    public let team: String?
    /// Nil when the entitlements could not be read.
    public let isSandboxed: Bool?

    public static func read(_ bundle: URL) -> CodeFacts {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return CodeFacts(signer: nil, team: nil, isSandboxed: nil)
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let values = information as? [String: Any]
        else {
            return CodeFacts(signer: nil, team: nil, isSandboxed: nil)
        }
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let signer = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let sandbox = entitlements.map { ($0["com.apple.security.app-sandbox"] as? Bool) == true }
        return CodeFacts(signer: signer, team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                         isSandboxed: certificates.isEmpty ? nil : sandbox ?? false)
    }
}
