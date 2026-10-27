import BrimCore
import BrimOps
import BrimProtocol
import BrimScan
import Foundation

struct RemovalDiscovery: Sendable {
    let footprint: Footprint
}

struct RemovalPreview: Sendable {
    let footprint: Footprint
    let evaluated: EvaluatedFootprint
    let report: CapabilitySearchReport?
    let payloads: [String: [String]]
    let installation: HomebrewInstallation?

    func plan(intent: PlanIntent, root: FileSystemRoot) -> Plan {
        let dock = DockShortcutReview(root: root)
        return Planner().createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision,
                                    capabilityReport: report, receiptPayloads: payloads, dockPinnedPaths: dock.pins)
            .attaching(report).recording(installation).recordingDockShortcutError(dock.failure)
    }
}

extension BrimService {
    func inspectionPreview(identity: Identity) async throws -> Footprint {
        let key = identity.withoutDerivedSurfaces()
        return try await inspectionPreviews.value(for: key) { try await self.inspectRemoval(identity: key) }
    }

    func inspectRemoval(identity: Identity) async throws -> Footprint {
        let footprint = try await removalDiscovery(identity: identity).footprint
        try Task.checkCancellation()
        let accounting = await StorageAccountant().account(for: footprint.items)
        try Task.checkCancellation()
        return accounting.applying(to: footprint)
    }

    func removalDiscovery(identity: Identity) async throws -> RemovalDiscovery {
        try Task.checkCancellation()
        let key = identity.withoutDerivedSurfaces()
        if let preview = await removalPreviews.cached(key) {
            return RemovalDiscovery(footprint: preview.footprint)
        }
        return try await removalDiscoveries.value(for: key) { try await self.discoverRemoval(identity: key) }
    }

    private func discoverRemoval(identity: Identity) async throws -> RemovalDiscovery {
        let resolved = try await enriched(identity)
        let footprint = try await FootprintProjector(engine: engine).project(identity: resolved.identity, in: root)
        return RemovalDiscovery(footprint: footprint.mergingCompleteness(resolved.completeness))
    }

    func removalPreview(identity: Identity) async throws -> RemovalPreview {
        let key = identity.withoutDerivedSurfaces()
        return try await removalPreviews.value(for: key) { try await self.prepareRemovalPreview(identity: key) }
    }

    private func prepareRemovalPreview(identity: Identity) async throws -> RemovalPreview {
        let discovery = try await removalDiscovery(identity: identity)
        let package = await Self.homebrewInstallation(for: discovery.footprint.identity, in: root)
        let footprint = discovery.footprint.mergingCompleteness(package.completeness)
        let evaluated = await safetyEngine.evaluate(footprint: footprint, useCachedProtection: true)
        let payloads = reviewedReceiptPayloads(in: evaluated)
        // Search the possible removal scope once. The planner still emits
        // actions only for the current selection, and apply rediscovers it all.
        let possible = Set(evaluated.items.compactMap { item -> String? in
            guard case .unselected = item.selection else { return nil }
            return item.footprintItem.evidence.url.path
        })
        let intent = PlanIntent(type: .uninstall, subjectIdentity: footprint.identity).tickingByHand(possible)
        let report = await registrationSearchReport(evaluated: evaluated, intent: intent,
                                                    footprint: footprint, payloads: payloads)
        try Task.checkCancellation()
        return RemovalPreview(footprint: footprint, evaluated: evaluated, report: report,
                              payloads: payloads, installation: package.installation)
    }

    public func preloadApplication(identity: Identity, includeReview: Bool) async {
        do {
            await refreshRemovalPreviewInputs()
            if includeReview {
                async let inspection = inspectionPreview(identity: identity)
                async let review = removalPreview(identity: identity)
                _ = try await (inspection, review)
            } else {
                _ = try await inspectionPreview(identity: identity)
            }
        } catch {
            // A foreground request retries failed reads and owns their presentation.
        }
    }

    public func invalidateRemovalPreviews() async {
        if let invalidation = removalInvalidation {
            await invalidation.value; return
        }
        let task = Task {
            async let reviews: Void = removalPreviews.invalidate()
            async let discoveries: Void = removalDiscoveries.invalidate()
            async let ownership: Void = removalOwnership.invalidate()
            async let inspections: Void = inspectionPreviews.invalidate()
            _ = await (reviews, discoveries, ownership, inspections)
        }
        removalInvalidation = task
        await task.value
        removalInvalidation = nil
    }
}

private extension Footprint {
    func mergingCompleteness(_ other: ScanCompleteness) -> Footprint {
        Footprint(identity: identity, items: items, logicalSizeBytes: logicalSizeBytes,
                  reclaimableSizeBytes: reclaimableSizeBytes, snapshotPinnedBytes: snapshotPinnedBytes,
                  completeness: completeness.merging(other))
    }
}
