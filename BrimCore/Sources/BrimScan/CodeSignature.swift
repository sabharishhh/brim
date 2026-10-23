import Foundation
import Security
import BrimCore

/// Reads the signature on the code a registration points at. A basic
/// validation, not a full one, which hashes every resource and takes too
/// long for something Xcode's size; the question is who signed it and
/// whether the signature holds.
public enum CodeSignature {

    public static func state(of url: URL, recordedTeam: String?) -> SigningState {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else {
            return .notChecked("macOS could not read any code at this path.")
        }

        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let found = (information as? [String: Any])?["teamid"] as? String

        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        if valid == errSecCSUnsigned { return .unsigned }
        guard valid == errSecSuccess else {
            return .invalid(message(for: valid))
        }
        guard read == errSecSuccess else {
            return .notChecked("The signature is valid but macOS would not say who made it.")
        }

        // A team that changed since macOS recorded it is the finding. Claimed only
        // when both are known.
        if let recordedTeam, let found, recordedTeam != found {
            return .teamChanged(recorded: recordedTeam, found: found)
        }
        return .valid(team: found ?? recordedTeam)
    }

    static func message(for status: OSStatus) -> String {
        if let text = SecCopyErrorMessageString(status, nil) as String? { return text }
        return "macOS reported error \(status)."
    }
}
