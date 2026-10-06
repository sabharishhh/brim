import BrimCore
import BrimOps
import BrimProtocol
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
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

    func recheckRemovals(installed: Set<String>) async -> [RemovalRecheck] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        let entries = await (try? journalStore.recentEntries()) ?? []
        var observed = 0
        var results: [RemovalRecheck] = []
        for entry in entries where RemovalReturn.isSettled(entry) {
            guard observed < RemovalReturn.pathLimit, clock.now < deadline, !Task.isCancelled else { break }
            // A removal or Put Back in progress is mid-change; its paths say
            // nothing yet.
            guard !isOperating(on: entry.planId),
                  let plan = try? await planStore.load(planId: entry.planId),
                  plan.intent.type == .uninstall else { continue }
            let paths = RemovalReturn.paths(plan: plan, entry: entry)
            guard !paths.isEmpty else { continue }
            observed += paths.count
            let back = RemovalReturn.outermost(paths.filter(RemovalReturn.isBack))
            results.append(RemovalRecheck(
                planId: plan.planId, state: RemovalReturn.state(back: back, plan: plan, installed: installed),
                observedAt: Date()
            ))
        }
        return results
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

/// Whether what a confirmed removal took has come back.
///
/// Only the steps that take something away are asked about. A vendor
/// uninstaller Brim revealed is meant to stay, and an unregistered or
/// unlocked path is the same path a later step moves to the Trash.
enum RemovalReturn {
    /// Enough for a hundred ordinary removals; a few thousand `lstat`
    /// calls take milliseconds.
    static let pathLimit = 5000

    /// Finished, checked at least once, and not put back. A removal never
    /// checked is the pending recheck's to look at, and one put back has
    /// its files back on purpose.
    static func isSettled(_ entry: JournalEntry) -> Bool {
        entry.restoredAt == nil && entry.restoreOutcomes?.isEmpty != false
            && !entry.stepOutcomes.isEmpty && entry.verifications?.isEmpty == false
    }

    /// What the removal took: steps that succeeded, less anything its
    /// first check found still there. The first check, not the latest:
    /// once the person reviews a removal that came back, the latest check
    /// lists those paths as remaining, and reading that as "never went"
    /// would turn them back into "still gone".
    static func paths(plan: Plan, entry: JournalEntry) -> [String] {
        let neverWent = entry.verifications?.first?.remainingPaths ?? []
        return plan.steps.compactMap { step in
            guard [.trashPath, .trashPathPrivileged, .removeLaunchdPlist].contains(step.kind),
                  let outcome = entry.stepOutcomes[step.index], outcome == "ok" || outcome == "already_gone",
                  !neverWent.contains(step.target) else { return nil }
            return step.target
        }
    }

    /// On the disk again. A preference file `cfprefsd` wrote back empty
    /// holds no settings, which the removal's own check already allows.
    static func isBack(_ path: String) -> Bool {
        guard PathObservation.observe(path).isPresent else { return false }
        return !(PreferenceDomains.domain(forPlistAt: path) != nil && PreferenceDomains.isEmptyStub(atPath: path))
    }

    /// One row for a folder that came back with what is inside it.
    static func outermost(_ paths: [String]) -> [String] {
        let sorted = paths.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept.sorted()
    }

    static func state(back: [String], plan: Plan, installed: Set<String>) -> RemovalRecheck.State {
        let subject = plan.intent.subjectIdentity
        // A copy that stayed when this one was removed was already
        // installed, so the identifier being installed says nothing new.
        let stayed = Set((plan.survivingCopies ?? []).compactMap(\.bundleID))
        if let identifier = subject.bundleID, !identifier.isEmpty, !stayed.contains(identifier),
           installed.contains(identifier) {
            return .installedAgain
        }
        if let identifier = subject.bundleID, back.contains(where: { isBundle($0, identifiedAs: identifier) }) {
            return .installedAgain
        }
        return back.isEmpty ? .stillGone : .cameBack(back)
    }

    private static func isBundle(_ path: String, identifiedAs identifier: String) -> Bool {
        guard path.hasSuffix(".app"),
              let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") else { return false }
        return (info["CFBundleIdentifier"] as? String)?.lowercased() == identifier.lowercased()
    }
}
