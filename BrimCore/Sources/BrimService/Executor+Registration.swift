import BrimCore
import BrimOps
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
extension Executor {
    static func unregisterComponent(step: Step, plan: Plan, outcomes: [Int: String]) async -> String {
        do {
            // The helper proves protected-copy absence because the app cannot traverse its store.
            let removedRecovery = RecoveryCopy.identifier(for: step.target) != nil
                && plan.steps.contains {
                    $0.kind == .trashPathPrivileged && $0.effectiveDisposition == .delete
                        && $0.target == step.target && outcomes[$0.index] == "ok"
                }
            guard removedRecovery || PathObservation.observe(step.target).isAbsent else {
                throw NSError(domain: "BrimRegistration", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The application path is still occupied. Its registration was kept."
                ])
            }
            if try componentIsAlreadyUnregistered(step: step, plan: plan) {
                return "already_gone"
            }
            try await LaunchServicesRegistration.unregisterBounded(bundlePath: step.target)
            return "ok"
        } catch {
            return "launch_services_registration_remains: \(error.localizedDescription)"
        }
    }

    static func removeRecoveryCopy(
        _ step: Step, using remover: (@Sendable (String, TargetFingerprint) async -> String?)?
    ) async throws {
        guard RecoveryCopy.identifier(for: step.target) != nil,
              let fingerprint = step.targetFingerprint, let remover else {
            throw NSError(domain: "BrimRecovery", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The recovery copy could not be removed by the helper."
            ])
        }
        if let refusal = await remover(step.target, fingerprint) {
            throw NSError(domain: "BrimRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey: refusal])
        }
    }

    /// A declared embedded app may never have been opened. Register its reviewed
    /// path so tccutil can resolve it without launching it.
    static func resetPrivacy(step: Step, plan: Plan) async throws {
        if try LaunchServicesRegistration.checkedApplicationURLs(forBundleID: step.target).isEmpty,
           let component = plan.intent.subjectIdentity.identitySurface?.components.first(where: {
               $0.bundleIdentifier == step.target && $0.path.hasSuffix(".app")
                   && PathObservation.observe($0.path).isPresent
           }) {
            try await LaunchServicesRegistration.registerBounded(bundlePath: component.path)
        }
        try await PrivacyGrants.resetAllBounded(bundleID: step.target)
    }

    /// Absence of an exact registered path is success. A failed lookup throws.
    static func componentIsAlreadyUnregistered(
        step: Step, plan: Plan,
        lookup: (String) throws -> [URL] = LaunchServicesRegistration.checkedApplicationURLs
    ) throws -> Bool {
        guard let identifier = step.registrationBundleID ?? plan.intent.subjectIdentity.identitySurface?.components
            .first(where: { $0.path == step.target })?.bundleIdentifier else { return false }
        return try !lookup(identifier)
            .contains(where: { $0.standardizedFileURL.path == step.target })
    }
}
