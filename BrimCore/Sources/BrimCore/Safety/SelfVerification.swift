import Foundation
import Security

public enum SelfVerificationError: Error {
    case codeSignatureCheckFailed(OSStatus)
    case tamperedBinary
    case databaseCorrupt(String)
}

public struct SelfVerification: Sendable {
    
    public static func verifyCodeSignature() throws {
        var codeObj: SecCode? = nil
        // Get the code object for the current process
        let getStatus = SecCodeCopySelf(SecCSFlags(rawValue: 0), &codeObj)
        guard getStatus == errSecSuccess, let code = codeObj else {
            throw SelfVerificationError.codeSignatureCheckFailed(getStatus)
        }
        
        // Check validity against its own designated requirement
        let checkStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 16), nil)
        
        guard checkStatus == errSecSuccess else {
            if checkStatus == errSecCSUnsigned {
                // If it's completely unsigned, we might be running locally in Xcode / swift run.
                // Depending on strictness, we could allow it, but the spec says "check our own code signature".
                // We'll throw tamperedBinary. (Tests might need a bypass if they are unsigned).
            }
            throw SelfVerificationError.tamperedBinary
        }
    }
}
