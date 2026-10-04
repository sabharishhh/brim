import BrimCore
import BrimProtocol
import Foundation

/// What a removal comes to, put the way a person reads it: what went, and,
/// quietly, anything that is still on this Mac.
///
/// The result used to list every kind of registration Brim had read,
/// every kind the app does not declare, and every kind macOS will not let
/// anyone list for another app, under a caution mark. eqMac's removal took
/// the app, its audio driver, its settings and its caches, and the sound
/// device left the menu at once, but the screen read as a partial removal
/// because configuration profiles cannot be fully read on this Mac. What
/// Brim never had reason to look for is not news about this app, so it is
/// not shown. What did not go still is, plainly and without alarm.
public struct RemovalSummary: Sendable {
    /// One footprint group's share of what went.
    public struct Went: Identifiable, Sendable, Equatable {
        public let loss: FootprintLoss
        public let count: Int
        public let bytes: Int64

        public var id: FootprintLoss {
            loss
        }
    }

    /// Something still on this Mac, in a few words.
    public struct Stayed: Identifiable, Sendable, Equatable {
        public let label: String
        public let detail: String?
        public var count: Int?

        public var id: String {
            label + (detail ?? "")
        }
    }

    public let headline: String
    public let subline: String
    /// The thing asked for went. A removal that leaves something the person
    /// chose to keep, or something macOS keeps, is still a removal.
    public let isDone: Bool
    public let went: [Went]
    /// Launch Services, privacy and background records Brim retracted.
    public let records: Int
    public let stayed: [Stayed]
    /// Paths to select in Finder: what is left and can be moved by hand.
    public let revealable: [String]

    public init(result: VerificationResult, plan: Plan?, groups: [UninstallReviewGroup] = []) {
        let groups = groups.isEmpty ? plan.map(UninstallExecutionModel.grouped) ?? [] : groups
        let report = result.report
        let unknown = Set(report?.unknownPaths ?? [])
        let isGone: (Step) -> Bool = { !result.remainingPaths.contains($0.target) && !unknown.contains($0.target) }
        let goneSteps = groups.flatMap(\.steps).filter(isGone)

        went = groups.compactMap { group in
            let steps = group.steps.filter(isGone)
            guard !steps.isEmpty else { return nil }
            return Went(loss: group.loss, count: steps.count, bytes: steps.reduce(0) { $0 + $1.expectedBytes })
        }
        let stillListed = report?.registrationObservations?.contains { !$0.remaining.isEmpty } == true
        records = stillListed ? 0 : (plan?.steps ?? []).filter {
            [.unregisterLaunchServices, .unloadLaunchdJob].contains($0.kind)
        }.count

        let name = plan?.intent.subjectIdentity.name ?? ""
        let bundle = Self.bundleStep(in: plan)
        if let bundle, !name.isEmpty {
            isDone = isGone(bundle)
            headline = isDone ? "\(name) is gone" : "\(name) is still here"
        } else {
            isDone = !goneSteps.isEmpty && result.remainingPaths.isEmpty
            headline = goneSteps.isEmpty ? "Nothing was removed" : "Removed"
        }
        if isDone || !goneSteps.isEmpty {
            subline = Self.space(of: goneSteps, result: result)
        } else {
            subline = result.reason?.components(separatedBy: "\n").first ?? "It could not be moved."
        }

        let staying = Self.stayed(result: result, report: report, unknown: unknown)
        stayed = staying.rows
        revealable = staying.paths
    }

    private static func bundleStep(in plan: Plan?) -> Step? {
        guard let plan, plan.intent.type == .uninstall, plan.intent.explicitTargets.isEmpty,
              let host = plan.intent.subjectIdentity.bundlePath else { return nil }
        return plan.steps.first {
            $0.executionPhase == .appBundle && $0.target == host
                && [.trashPath, .trashPathPrivileged].contains($0.kind)
        }
    }

    /// Where the space went, by where it can be had back from.
    private static func space(of steps: [Step], result: VerificationResult) -> String {
        func total(_ include: (Step) -> Bool) -> Int64 {
            steps.filter(include).reduce(0) { $0 + $1.expectedBytes }
        }
        let parts = [
            (total { $0.effectiveDisposition == .trash && $0.kind != .trashPathPrivileged }, "in the Trash"),
            (total { $0.effectiveDisposition == .trash && $0.kind == .trashPathPrivileged }, "set aside"),
            (total { $0.effectiveDisposition == .delete }, "deleted")
        ].filter { $0.0 > 0 }.map { "\(ByteText.short($0.0)) \($0.1)" }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return steps.count == 1 ? "1 item removed" : "\(steps.count) items removed"
    }

    private static func stayed(
        result: VerificationResult, report: RemovalReport?, unknown: Set<String>
    ) -> (rows: [Stayed], paths: [String]) {
        var rows: [Stayed] = []
        let kept = report?.keptByMacOS ?? []
        rows += kept.map { Stayed(label: $0.what, detail: $0.why) }
        let refused = Set(kept.map(\.what))
        let failed = result.remainingPaths.subtracting(unknown).sorted()
            .filter { !refused.contains(($0 as NSString).lastPathComponent) }
        rows += failed.map { Stayed(label: ($0 as NSString).lastPathComponent, detail: "Could not be moved") }
        for observation in report?.registrationObservations ?? [] where !observation.remaining.isEmpty {
            rows.append(Stayed(label: observation.capability.title, detail: "Still listed by macOS"))
        }
        let unticked = report?.leftUnticked ?? []
        if !unticked.isEmpty {
            rows.append(Stayed(label: "Left unticked",
                               detail: unticked.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                               count: unticked.count))
        }
        let protected = (report?.protectedItems ?? []).filter { $0.presence == .present }
        if !protected.isEmpty {
            rows.append(Stayed(label: "Kept on purpose",
                               detail: protected.map { ($0.target as NSString).lastPathComponent }
                                   .joined(separator: ", "),
                               count: protected.count))
        }
        if !unknown.isEmpty {
            rows.append(Stayed(label: "Could not confirm", detail: nil, count: unknown.count))
        }
        for check in report?.unansweredChecks ?? [] {
            rows.append(Stayed(label: check.capability.title, detail: "Could not be checked"))
        }
        let paths = Set(failed + unticked + protected.map(\.target).filter { $0.hasPrefix("/") })
        return (rows, paths.sorted())
    }
}
