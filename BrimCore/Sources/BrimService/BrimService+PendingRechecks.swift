import BrimCore
import Foundation

public extension BrimService {
    func recheckPendingRemovals() async {
        guard !hasRecheckedPendingRemovals else { return }
        hasRecheckedPendingRemovals = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        let entries = await (try? journalStore.recentEntries()) ?? []
        let candidates = PendingRemovalRecheck.ordered(entries)
        var checked = 0
        for candidate in candidates {
            guard checked < 3, clock.now < deadline, !Task.isCancelled else { break }
            guard let plan = try? await planStore.load(planId: candidate.planId),
                  PendingRemovalRecheck.isRemoval(plan),
                  let current = try? await journalStore.load(planId: candidate.planId),
                  PendingRemovalRecheck.needsCheck(current) else { continue }
            // verify owns the existing operation lease, so an active removal
            // or restoration cannot overlap this readback.
            checked += 1
            _ = try? await verify(planId: candidate.planId)
        }
    }
}

enum PendingRemovalRecheck {
    static func ordered(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.filter(needsCheck).sorted {
            let lhs = $0.verifications?.last?.observedAt ?? $0.startedAt
            let rhs = $1.verifications?.last?.observedAt ?? $1.startedAt
            return lhs == rhs ? $0.planId.uuidString < $1.planId.uuidString : lhs < rhs
        }
    }

    static func needsCheck(_ entry: JournalEntry) -> Bool {
        guard entry.restoredAt == nil, entry.restoreOutcomes?.isEmpty != false,
              !entry.stepOutcomes.isEmpty else { return false }
        guard let latest = entry.verifications?.last else { return true }
        // Preserved shared items and recovery copies alone do not queue
        // perpetual checks. They remain visible in the saved result.
        return !latest.success || !latest.remainingPaths.isEmpty
    }

    static func isRemoval(_ plan: Plan) -> Bool {
        plan.intent.type == .uninstall && plan.intent.explicitTargets.isEmpty
            && plan.steps.contains {
                $0.kind == .trashPath || $0.kind == .trashPathPrivileged || $0.kind == .removeLaunchdPlist
            }
    }
}
