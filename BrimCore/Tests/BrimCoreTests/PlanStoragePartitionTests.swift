import BrimCore
import Foundation
import Testing

struct PlanStoragePartitionTests {
    /// Helper quarantine was counted as recoverable Trash space, and review
    /// promised Put Back even though the helper exposes no restore operation.
    @Test func helperAndDetectionBytesDoNotBecomeTrashOrImmediateSavings() {
        let steps = [
            step(.trashPath, bytes: 32, disposition: .trash),
            step(.trashPath, bytes: 16, disposition: .delete),
            step(.trashPathPrivileged, bytes: 64, disposition: .trash),
            step(.revealVendorUninstaller, bytes: 8, disposition: .trash)
        ]
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Files")),
                        steps: steps, excludedItems: [], expectedTotalBytes: 120)
        #expect(plan.trashedBytes == 32)
        #expect(plan.immediatelyFreedBytes == 16)
        #expect(plan.setAsideBytes == 64)
    }

    private func step(_ kind: StepKind, bytes: Int64, disposition: StepDisposition) -> Step {
        Step(index: 0, kind: kind, target: "/fixture", targetFingerprint: nil, tier: .B,
             evidence: "Fixture", expectedBytes: bytes, capability: .ok, reversible: false,
             costOfError: .medium, disposition: disposition)
    }
}
