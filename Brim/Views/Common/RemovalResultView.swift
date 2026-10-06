import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces
/// What a removal did: what went, and quietly, anything still on this Mac.
///
/// It used to set out every count the check produced: places checked,
/// kinds of registration read, kinds the app does not declare, and kinds
/// macOS will not list for another app, each under its own heading. A
/// clean removal read as a partial one. Now the outcome leads, the groups
/// that went follow in the review's order, and only what actually stayed
/// is mentioned, in secondary text rather than a warning.
struct RemovalResultView: View {
    let result: VerificationResult
    var plan: Plan?
    var groups: [UninstallReviewGroup] = []
    var spaceExplanation: String?
    /// Off when the result sits inside something that already scrolls.
    var scrolls = true

    /// The mark has settled. It resolves once, and only when the removal
    /// did what was asked.
    @State private var resolved = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: RemovalSummary {
        RemovalSummary(result: result, plan: plan, groups: groups)
    }

    var body: some View {
        let summary = summary
        if scrolls {
            ScrollView { column(summary).padding(20) }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            column(summary)
        }
    }

    private func column(_ summary: RemovalSummary) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            status(summary)
            if let cleanup = result.toolCleanup {
                FactSection(title: "Tool cleanup") {
                    FactRow(label: cleanup.command, detail: cleanup.scope)
                }
            } else if !summary.went.isEmpty || summary.records > 0 {
                went(summary)
            }
            if let record = result.packageRecord {
                FactSection(title: "Package record") {
                    FactRow(label: record.installation.token, detail: record.detail)
                }
            }
            if !summary.stayed.isEmpty {
                stayed(summary)
            }
            notes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status

    private func status(_ summary: RemovalSummary) -> some View {
        let headline = result.toolCleanup?.headline ?? summary.headline
        let detail = result.toolCleanup?.detail ?? summary.subline
        let done = result.toolCleanup == nil ? summary.isDone : result.success
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: done ? "checkmark" : "exclamationmark")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(done ? Palette.success : Palette.caution)
                .frame(width: 52, height: 52)
                .background((done ? Palette.success : Palette.caution).opacity(0.14), in: .circle)
                // Settles in place once. Under Reduce Motion it only fades.
                .scaleEffect(done && !resolved && !reduceMotion ? 0.86 : 1)
                .opacity(done && !resolved ? 0 : 1)
                .onAppear {
                    guard done, !resolved else { return }
                    withAnimation(Motion.resolved(Motion.resolve, reduceMotion: reduceMotion)) { resolved = true }
                }
            VStack(alignment: .leading, spacing: 3) {
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

    // MARK: - Went

    private func went(_ summary: RemovalSummary) -> some View {
        FactSection(title: "Removed") {
            ForEach(Array(summary.went.enumerated()), id: \.element.id) { index, went in
                if index > 0 {
                    FactDivider()
                }
                WentRow(symbol: went.loss.symbol, label: went.loss.navigationTitle,
                        value: went.bytes > 0 ? ByteText.short(went.bytes) : went.count.formatted())
            }
            if summary.records > 0 {
                if !summary.went.isEmpty {
                    FactDivider()
                }
                WentRow(symbol: "gearshape", label: "System records", value: summary.records.formatted())
            }
        }
    }

    // MARK: - Stayed

    private func stayed(_ summary: RemovalSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Still on this Mac")
                .font(.brimFacts.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(summary.stayed) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.label).foregroundStyle(Palette.inkSecondary)
                    if let detail = item.detail {
                        Text(detail).foregroundStyle(Palette.inkTertiary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if let count = item.count {
                        Text(count.formatted()).monospacedDigit().foregroundStyle(Palette.inkTertiary)
                    }
                }
                .font(.brimFacts)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel([item.label, item.detail, item.count?.formatted()].compactMap(\.self)
                    .joined(separator: ", "))
            }
            if !summary.revealable.isEmpty {
                // Selected, not just opened: Finder can move what is left.
                Button(summary.revealable.count == 1 ? "Show in Finder" : "Show All in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(summary.revealable.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(.link)
                .font(.brimFacts)
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Notes

    /// Next steps that depend on macOS, and the space note, as quiet lines.
    @ViewBuilder
    private var notes: some View {
        let actions = result.followUpActions ?? []
        if !actions.isEmpty || spaceExplanation != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.sentence)
                            .fixedSize(horizontal: false, vertical: true)
                        if action == .loginItemsSettings,
                           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            Link("Open Login Items", destination: url)
                        }
                    }
                }
                if let spaceExplanation {
                    Text(spaceExplanation)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkTertiary)
            .padding(.leading, 4)
        }
    }
}

/// A group that went: its symbol, its name, how much, and a check.
private struct WentRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 18)
            Text(label).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(Palette.inkSecondary)
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.success)
        }
        .font(.brimFacts)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(label), \(value), removed")
    }
}
