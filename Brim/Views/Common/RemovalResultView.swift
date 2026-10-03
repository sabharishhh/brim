import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces
/// What a removal did, checked afterwards, in one column.
///
/// It used to be a centred seal and sentence, then a card of counts, then a
/// second card of sizes, each aligned and styled its own way, and the whole
/// thing was taller than the window: Done sat under its bottom edge. Now it
/// scrolls, reads down the left like the rest of the app, and every figure
/// is a row in a section with the label on the left and the number on the
/// right, the way System Settings sets out facts.
///
/// The facts are kept apart as `RemovalReport` keeps them: what went, what
/// was checked again and found gone, and what is still here and why.
struct RemovalResultView: View {
    let result: VerificationResult
    var plan: Plan?
    var groups: [UninstallReviewGroup] = []
    var spaceExplanation: String?
    /// Off when the result sits inside something that already scrolls.
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { column.padding(20) }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            column
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 20) {
            status
            if let observedAt = result.observedAt {
                HStack(spacing: 4) {
                    Text("Checked")
                    Text(observedAt, style: .date)
                    Text(observedAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let cleanup = result.toolCleanup {
                FactSection(title: "Tool cleanup") {
                    FactRow(label: cleanup.command, detail: cleanup.scope)
                }
            }
            if result.toolCleanup == nil, let plan, !gone.isEmpty {
                removed(plan)
            }
            if result.toolCleanup == nil, let report = result.report {
                checked(report)
            }
            if let record = result.packageRecord {
                FactSection(title: "Package record") {
                    FactRow(label: record.installation.token, detail: record.detail)
                }
            }
            if let shared = result.report?.sharedIdentityProtection {
                FactSection(title: "Shared identity") {
                    FactRow(label: shared.identifier,
                            detail: "Privacy permissions were not reset for this shared identifier.")
                    FactDivider()
                    FactRow(label: "Reviewed protecting installations",
                            detail: shared.installations.map { $0.bundlePath ?? $0.name }.joined(separator: ", "))
                }
            }
            if let report = result.report {
                RegistrationResultSection(report: report)
            }
            stillHere
            if let actions = result.followUpActions, !actions.isEmpty {
                FactSection(title: "One more step") {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        if index > 0 {
                            FactDivider()
                        }
                        FactRow(label: action.sentence)
                        if action == .loginItemsSettings,
                           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            Link("Open Login Items", destination: url)
                        }
                    }
                }
            }
            if let spaceExplanation {
                Label(spaceExplanation, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Removed

    private var gone: [Step] {
        groups.flatMap(\.steps).filter { isConfirmedGone($0.target) }
    }

    private func isConfirmedGone(_ path: String) -> Bool {
        !result.remainingPaths.contains(path) && result.report?.unknownPaths?.contains(path) != true
    }

    private func removed(_: Plan) -> some View {
        let steps = gone
        let setAside = steps.filter { $0.kind == .trashPathPrivileged && $0.effectiveDisposition == .trash }
            .reduce(0) { $0 + $1.expectedBytes }
        let trashed = steps.filter { $0.effectiveDisposition == .trash && $0.kind != .trashPathPrivileged }
            .reduce(0) { $0 + $1.expectedBytes }
        let kinds = groups.compactMap { group -> (String, [Step])? in
            let went = group.steps.filter { isConfirmedGone($0.target) }
            return went.isEmpty ? nil : (group.title, went)
        }
        return VStack(alignment: .leading, spacing: 20) {
            FactSection(
                title: "Removed",
                footer: removalFooter(steps)
            ) {
                FactRow(label: "Items", value: steps.count.formatted())
                if trashed > 0 {
                    FactDivider()
                    FactRow(label: "In the Trash", value: ByteText.short(trashed))
                }
                if setAside > 0 {
                    FactDivider()
                    FactRow(label: "Set aside", value: ByteText.short(setAside))
                }
                FactDivider()
                FactRow(label: "Free space increased", value: measuredSpaceIncrease)
            }
            if kinds.count > 1 {
                FactSection(title: "By kind") {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                        if index > 0 {
                            FactDivider()
                        }
                        FactRow(
                            label: kind.0,
                            value: "\(kind.1.count.formatted()) · "
                                + (kind.1.contains { $0.sizeIsKnown == false }
                                    ? "Not measured" : ByteText.short(kind.1.reduce(0) { $0 + $1.expectedBytes }))
                        )
                    }
                }
            }
        }
    }

    private var measuredSpaceIncrease: String {
        guard result.freeSpaceMeasured == true else { return "Unavailable" }
        return result.recoveredBytes > 0 ? ByteText.short(result.recoveredBytes) : "No increase measured"
    }

    private func removalFooter(_ steps: [Step]) -> String {
        var facts = ["File sizes are estimates. Other activity on this Mac can change free space."]
        if steps.contains(where: { $0.effectiveDisposition == .trash && $0.kind != .trashPathPrivileged }) {
            facts.append("Items in the Trash still occupy space until it is emptied.")
        }
        if steps.contains(where: { $0.kind == .trashPathPrivileged && $0.effectiveDisposition == .trash }) {
            facts.append("Items set aside by the helper have no restore action in Brim.")
        }
        return facts.joined(separator: " ")
    }

    // MARK: - Checked

    private func checked(_ report: RemovalReport) -> some View {
        FactSection(title: report.registrationObservations == nil ? "Recorded result" : "Checked again") {
            FactRow(label: "Places, all gone", value: report.checkedGone.formatted())
            if let explanation = searchGap?.explanation {
                FactDivider()
                FactRow(label: "Search incomplete", detail: explanation)
            }
            if report.registrationObservations != nil, !report.registrationsChecked.isEmpty {
                FactDivider()
                FactRow(
                    label: "Kinds of registration",
                    value: report.registrationsChecked.count.formatted(),
                    detail: report.registrationsChecked.map(\.title).joined(separator: ", ")
                )
            }
            if !report.declaredNone.isEmpty {
                FactDivider()
                FactRow(
                    label: "Not declared by the app",
                    value: report.declaredNone.count.formatted(),
                    detail: report.declaredNone.map(\.title).joined(separator: ", ")
                )
            }
        }
    }

    // MARK: - Still here

    @ViewBuilder
    private var stillHere: some View {
        let report = result.report
        let kept = report?.keptByMacOS ?? []
        let protected = report?.protectedItems ?? []
        let unticked = report?.leftUnticked ?? []
        let other = report?.stillThere ?? 0
        let protectedPaths = protected.map(\.target).filter { $0.hasPrefix("/") }
        let remaining = Array(Set(result.remainingPaths.sorted() + unticked + protectedPaths)
            .subtracting(report?.unknownPaths ?? [])).sorted()
        if !kept.isEmpty || !protected.isEmpty || !unticked.isEmpty || other > 0 {
            let title = protected.contains(where: { $0.presence == .unknown }) ? "Kept or not checked" : "Still here"
            FactSection(title: title) {
                ForEach(Array(kept.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        FactDivider()
                    }
                    FactRow(label: item.what, detail: item.why)
                }
                ForEach(Array(protected.enumerated()), id: \.offset) { index, item in
                    if !kept.isEmpty || index > 0 {
                        FactDivider()
                    }
                    let gap = item.presence == .unknown ? " Presence could not be checked." : ""
                    FactRow(label: (item.target as NSString).lastPathComponent, detail: item.reason + gap)
                }
                if other > 0 {
                    if !kept.isEmpty || !protected.isEmpty {
                        FactDivider()
                    }
                    FactRow(label: "Came back or failed", value: other.formatted())
                }
                if !unticked.isEmpty {
                    if !kept.isEmpty || !protected.isEmpty || other > 0 {
                        FactDivider()
                    }
                    FactRow(label: "Left unticked", value: unticked.count.formatted(),
                            detail: unticked.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                }
            }
            if !remaining.isEmpty {
                // Selected, not just opened: Finder can move what is left.
                Button(remaining.count == 1 ? "Show in Finder" : "Show All in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(remaining.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(.link)
                .font(.brimFacts)
                .padding(.top, -12)
                .padding(.leading, 4)
            }
        }
    }
}

extension RemovalResultView {
    // MARK: - Status

    private var status: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: .circle)
                .symbolEffect(.bounce, value: result.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(headline). \(detail)")
    }

    private var untickedCount: Int {
        result.report?.leftUnticked.count ?? 0
    }

    private var searchGap: ScanCompleteness? {
        result.report?.scanCompleteness ?? plan?.scanCompleteness
    }

    private var headline: String {
        if let cleanup = result.toolCleanup {
            return cleanup.headline
        }
        if let host = plan?.intent.subjectIdentity.bundlePath,
           plan?.intent.type == .uninstall, plan?.intent.explicitTargets.isEmpty == true,
           let bundleStep = plan?.steps.first(where: {
               $0.executionPhase == .appBundle && $0.target == host
                   && [.trashPath, .trashPathPrivileged].contains($0.kind)
           }),
           !result.remainingPaths.contains(bundleStep.target),
           result.report?.registrationObservations != nil {
            return "App removed"
        }
        if result.report?.unknownPaths?.isEmpty == false {
            return "Removal needs a check"
        }
        guard result.success else { return "Removal incomplete" }
        return "Selected items removed"
    }

    private var detail: String {
        if let cleanup = result.toolCleanup {
            return cleanup.detail
        }
        if result.report?.unknownPaths?.isEmpty == false
            || result.report?.registrationObservations?.contains(where: \.couldNotCheck) == true {
            return "Some locations could not be checked. See the details below."
        }
        if result.report?.registrationObservations?.contains(where: { !$0.remaining.isEmpty }) == true {
            return "Some registrations remain listed. See the next steps below."
        }
        guard result.success else { return result.reason ?? "Some actions could not be completed." }
        if searchGap?.isComplete == false {
            return "Selected items removed. The search was incomplete."
        }
        if untickedCount > 0 {
            return untickedCount == 1 ? "1 item you left unticked stays"
                : "\(untickedCount) items you left unticked stay"
        }
        if let record = result.packageRecord, record.state != .absent {
            return record.detail
        }
        if result.report?.protectedItems.contains(where: { $0.presence == .unknown }) == true {
            return "Selected items removed. Some protected items could not be checked."
        }
        if result.report?.keptByMacOS.isEmpty == false || result.report?.protectedItems.isEmpty == false {
            return "Selected items removed. Protected or shared items remain."
        }
        if plan?.intent.explicitTargets.isEmpty == false {
            return "Every selected path checked again"
        }
        if result.report?.sharedIdentityProtection != nil {
            return "Selected items removed. Identifier-wide privacy permissions were not reset."
        }
        return "Selected locations checked again"
    }

    private var symbol: String {
        result.success ? "checkmark" : "exclamationmark"
    }

    private var tint: Color {
        result.success ? .accentColor : Palette.caution
    }
}
