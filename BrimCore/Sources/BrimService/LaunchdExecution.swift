import BrimCore
import BrimOps
import Foundation

enum LaunchdExecution {
    static func verifyModification(_ step: Step) throws {
        guard let fingerprint = step.targetFingerprint,
              let modified = try FileManager.default.attributesOfItem(
                  atPath: step.target
              )[.modificationDate] as? Date,
              // Stored plans use fractional ISO dates with millisecond precision.
              abs(modified.timeIntervalSince(fingerprint.mtime)) <= 0.001
        else {
            throw SafeOpsError.fingerprintMismatch
        }
        try SafeOps.verifyTargetFingerprint(targetPath: step.target,
                                            expectedDev: fingerprint.dev, expectedIno: fingerprint.ino)
    }

    static func stop(_ path: String, runtime: LaunchdRuntimeClient) async throws -> (outcome: String, verified: Bool) {
        do {
            let wasLoaded = try await runtime.stopWithReceipt(path)
            return (wasLoaded ? "ok" : "already_gone", true)
        } catch let LaunchdStopError.verificationFailedAfterStop(reason) {
            return ("stopped_unverified: \(reason)", false)
        }
    }
}
