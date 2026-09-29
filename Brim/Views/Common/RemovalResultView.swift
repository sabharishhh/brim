import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

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
                if let plan, !gone.isEmpty {
                    removed(plan)
                }
                if let report = result.report {
                    checked(report)
                }
                stillHere
                if let actions = result.followUpActions, !actions.isEmpty {
                    FactSection(title: "One more step") {
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            if index > 0 { FactDivider() }
                            FactRow(label: action.sentence)
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

    private var untickedCount: Int { result.report?.leftUnticked.count ?? 0 }

    private var headline: String {
        guard result.success else { return "Some of it remains" }
        if result.followUpActions?.isEmpty == false { return "One more step" }
        // Everything ticked went. What was left unticked is still here, and
        // "Nothing left" over it was read as everything.
        return untickedCount > 0 ? "Removed" : "Nothing left"
    }

    private var detail: String {
        guard result.success else { return result.reason ?? "Some of it is still on disk" }
        if untickedCount > 0 {
            return untickedCount == 1 ? "1 item you left unticked stays" : "\(untickedCount) items you left unticked stay"
        }
        return "Every place checked again"
    }

    private var symbol: String {
        result.success ? "checkmark" : "exclamationmark"
    }

    private var tint: Color {
        result.success ? .accentColor : Palette.caution
    }

    // MARK: - Removed

    private var gone: [Step] {
        groups.flatMap(\.steps).filter { !result.remainingPaths.contains($0.target) }
    }

    private func removed(_ plan: Plan) -> some View {
        let steps = gone
        let setAside = steps.filter { $0.kind == .trashPathPrivileged }.reduce(0) { $0 + $1.expectedBytes }
        let trashed = steps.filter { $0.effectiveDisposition == .trash && $0.kind != .trashPathPrivileged }
            .reduce(0) { $0 + $1.expectedBytes }
        let kinds = groups.compactMap { group -> (String, [Step])? in
            let went = group.steps.filter { !result.remainingPaths.contains($0.target) }
            return went.isEmpty ? nil : (group.title, went)
        }
        return VStack(alignment: .leading, spacing: 20) {
            FactSection(
                title: "Removed",
                footer: trashed > 0 ? "Space in the Trash comes back when it is emptied." : nil
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
                FactRow(label: "Freed now", value: result.recoveredBytes > 0 ? ByteText.short(result.recoveredBytes) : "None yet")
            }
            if kinds.count > 1 {
                FactSection(title: "By kind") {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                        if index > 0 { FactDivider() }
                        FactRow(
                            label: kind.0,
                            value: "\(kind.1.count.formatted()) · \(ByteText.short(kind.1.reduce(0) { $0 + $1.expectedBytes }))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Checked

    private func checked(_ report: RemovalReport) -> some View {
        FactSection(title: "Checked again") {
            FactRow(label: "Places, all gone", value: report.checkedGone.formatted())
            if !report.registrationsChecked.isEmpty {
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
                    label: "Never used by the app",
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
        let unticked = report?.leftUnticked ?? []
        let other = report?.stillThere ?? 0
        let remaining = result.remainingPaths.sorted() + unticked
        if !kept.isEmpty || !unticked.isEmpty || other > 0 {
            FactSection(title: "Still here") {
                ForEach(Array(kept.enumerated()), id: \.offset) { index, item in
                    if index > 0 { FactDivider() }
                    FactRow(label: item.what, detail: item.why)
                }
                if other > 0 {
                    if !kept.isEmpty { FactDivider() }
                    FactRow(label: "Came back or failed", value: other.formatted())
                }
                if !unticked.isEmpty {
                    if !kept.isEmpty || other > 0 { FactDivider() }
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

// MARK: - Sections

/// A titled group of facts on one surface, with hairlines between rows.
struct FactSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.brimFacts.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: Metrics.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.well, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A label on the left, its figure on the right, and a quieter line under
/// the label when there is more to say.
struct FactRow: View {
    let label: String
    var value: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .font(.brimFacts)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel([label, value, detail].compactMap(\.self).joined(separator: ", "))
    }
}

struct FactDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}
