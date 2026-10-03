import BrimCore
import Foundation

extension BrimService {
    public func useRecoveryVerifier(_ reader: (@Sendable () async throws -> [RecoveryCopy])?) async {
        recoveryVerifier = reader
    }

    public func useRecoveryCopies(
        reader: (@Sendable () async throws -> [RecoveryCopy])?,
        remover: (@Sendable (String, TargetFingerprint) async -> String?)?
    ) async {
        recoveryReader = reader
        await executor.setRecoveryRemover(remover)
    }

    func reviewedRecoveryCopies(for targets: [URL]) async throws -> [RecoveryCopy] {
        let requested = Set(targets.map(\.path).filter { RecoveryCopy.identifier(for: $0) != nil })
        guard !requested.isEmpty else { return [] }
        guard let recoveryReader else {
            throw ApplyError.validationFailed("Read the recovery copies before selecting them for cleanup.")
        }
        let copies = try await recoveryReader().filter { requested.contains($0.path) }
        guard Set(copies.map(\.path)) == requested else {
            throw ApplyError.validationFailed("A recovery copy changed or could not be checked. Refresh Leftovers.")
        }
        return copies.sorted { $0.path < $1.path }
    }

    func recoveryLeftovers() async -> [Leftover] {
        guard root.rootURL.path == "/", let recoveryReader else { return [] }
        guard !PathObservation.observe(RecoveryCopy.directory).isAbsent else { return [] }
        do {
            return try await recoveryReader().filter {
                RecoveryCopy.identifier(for: $0.path) != nil
            }.map(\.leftover)
        } catch {
            return [Leftover(url: URL(fileURLWithPath: RecoveryCopy.directory), size: 0,
                             category: .unclaimed,
                             evidence: "Recovery copies could not be checked. \(error.localizedDescription)",
                             capability: .needsHelper, sizeIsKnown: false)]
        }
    }

    func recoveryPresence(for plan: Plan) async -> [String: PathObservation] {
        let paths = plan.steps.map(\.target).filter { RecoveryCopy.identifier(for: $0) != nil }
        guard !paths.isEmpty else { return [:] }
        do {
            guard let reader = recoveryVerifier ?? recoveryReader else {
                throw ApplyError.validationFailed("The recovery copies could not be checked.")
            }
            let present = try await Set(reader().map(\.path))
            return Dictionary(uniqueKeysWithValues: Set(paths).map {
                ($0, present.contains($0) ? .present : .absent)
            })
        } catch {
            return Dictionary(uniqueKeysWithValues: Set(paths).map { ($0, .unknown(error.localizedDescription)) })
        }
    }
}

extension Plan {
    func addingRecoveryRemoval(_ copies: [RecoveryCopy]) -> Plan {
        guard !copies.isEmpty else { return self }
        var added = steps
        for copy in copies {
            added.append(Step(index: added.count, kind: .trashPathPrivileged, target: copy.path,
                              targetFingerprint: copy.fingerprint, tier: .A,
                              evidence: copy.leftover.evidence, expectedBytes: copy.sizeBytes,
                              capability: .needsHelper, reversible: false, costOfError: .high,
                              disposition: .delete, sizeIsKnown: copy.sizeIsKnown))
            if URL(fileURLWithPath: copy.path).pathExtension == "app" {
                added.append(Step(index: added.count, kind: .unregisterLaunchServices, target: copy.path,
                                  targetFingerprint: nil, tier: .A,
                                  evidence: "Retracts the registration for this recovery copy.", expectedBytes: 0,
                                  capability: .ok, reversible: false, costOfError: .medium,
                                  executionPhase: .registration, disposition: .delete))
            }
        }
        return Plan(planId: planId, createdAt: createdAt, engineVersion: engineVersion, osVersion: osVersion,
                    intent: intent, steps: added, excludedItems: excludedItems,
                    expectedTotalBytes: expectedTotalBytes + copies.reduce(0) { $0 + $1.sizeBytes },
                    scanCompleteness: scanCompleteness, capabilityReport: capabilityReport,
                    toolCleanupBinding: toolCleanupBinding, homebrewInstallation: homebrewInstallation,
                    survivingCopies: survivingCopies, protectedComponentIdentifiers: protectedComponentIdentifiers,
                    receiptPayloads: receiptPayloads)
    }
}
