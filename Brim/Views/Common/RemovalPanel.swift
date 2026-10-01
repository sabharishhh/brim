import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// The review, the removal and the proof, in the page's right pane rather
/// than a sheet over it.
///
/// A sheet hid the list the person had just built. Here the list stays in
/// view beside the review, the button carries the removal's progress, and
/// the result appears where the button was. Approval still comes from this
/// window only, through the same model the sheet used.
struct RemovalPanel: View {
    let intent: PlanIntent
    let service: any BrimServiceProtocol
    /// Told the moment the check proves what went, with those paths.
    let onRemoved: (Set<String>) -> Void
    /// Closed with the checked outcome, including a partial removal.
    /// Callers can offer recovery without claiming that every step succeeded.
    let onClose: (VerificationResult?) -> Void
    /// A result the check could not confirm: the page reads the disk again.
    let onUnverified: () -> Void
    /// A plan the service already made, reviewed as it is rather than
    /// planned again from the intent. A tool's own cleanup comes this way.
    var plan: Plan?
    /// Told whenever the review moves between waiting, running and done,
    /// so the page beside it knows when its own ticks may still change it.
    var onPhase: (UninstallExecutionModel.Phase) -> Void = { _ in }

    @StateObject private var model = UninstallExecutionModel()
    @State private var helperProblem: String?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: model.phase)
        .task(id: intent.id) {
            model.onRemoved = { paths in onRemoved(paths) }
            if let plan {
                model.adopt(plan: plan, service: service)
            } else {
                await model.prepare(intent: intent, service: service)
            }
        }
        .task(id: model.helperSteps) { await checkHelper() }
        .onChange(of: model.phase, initial: true) { _, phase in onPhase(phase) }
        .onKeyPress(.escape) {
            guard model.phase != .executing else { return .ignored }
            close()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review")
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(summary)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            RowAction(symbol: "xmark", help: "Close", action: close)
                .disabled(model.phase == .executing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// A tool's own cleanup: one command, whose effect the tool decides.
    private var isToolRun: Bool {
        guard let steps = model.plan?.steps, !steps.isEmpty else { return false }
        return steps.allSatisfy { $0.kind == .delegateToolCleanup }
    }

    private var summary: String {
        if isToolRun {
            return "1 command"
        }
        // Counted from the plan once there is one: a tool's own cleanup
        // names no locations up front, and "0 locations" would read as
        // nothing to do.
        let count = model.plan == nil ? intent.explicitTargets.count : model.removalSteps.count
        let places = count == 1 ? "1 location" : "\(count) locations"
        guard let plan = model.plan else { return count == 0 ? "" : places }
        let bytes = plan.immediatelyFreedBytes + plan.trashedBytes + plan.setAsideBytes
        return "\(places) · \(ByteText.short(bytes)) estimated"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            SkeletonRows(count: 5, showsTick: false)
                .padding(.horizontal, 8)
        case .ready, .executing:
            steps
        case let .verified(result):
            proof(result)
        case let .appliedButUnverified(reason):
            outcome(
                symbol: "checkmark.seal", tint: Palette.inkSecondary, title: "Removed, not checked",
                detail: reason
            )
        case let .failed(reason):
            outcome(symbol: "exclamationmark.triangle", tint: Palette.caution, title: "Stopped", detail: reason)
        }
    }

    private var steps: some View {
        List {
            if model.helperSteps > 0, let helperProblem {
                helperNotice(helperProblem)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(consequences, id: \.title) { consequence in
                Section {
                    // The group's title as its first row, not a pinned header:
                    // a pinned header is drawn on its own band with a rule under it.
                    Group {
                        Text(consequence.title)
                            .font(.brimGroupTitle)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                    ForEach(consequence.steps, id: \.index) { step in
                        StepRow(step: step)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                            .listRowBackground(Color.clear)
                    }
                }
                .listSectionSeparator(.hidden)
            }
            if let installation = model.plan?.homebrewInstallation {
                Section("Package record") {
                    Text(installation.explanation)
                        .font(.brimFacts)
                    if let command = installation.manualCommand {
                        Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy uninstall command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
            }
            if let copies = model.plan?.survivingCopies, !copies.isEmpty, intent.explicitTargets.isEmpty {
                Section("Shared identity") {
                    Text(
                        "Privacy permissions will not be reset because another installed component "
                            + "uses this identifier."
                    )
                    .font(.brimFacts)
                    ForEach(Array(copies.enumerated()), id: \.offset) { _, installation in
                        Text(installation.bundlePath ?? installation.name)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            StayingSection(items: model.staying)
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The plan is fixed once the button is pressed.
        .disabled(model.phase == .executing)
    }

    /// The steps by what happens to each, which is what a person weighs:
    /// back from the Trash, set aside by the helper, or gone for good.
    private var consequences: [(title: String, steps: [Step])] {
        let all = model.removalSteps.filter(\.kind.targetIsPath)
        let helper = all.filter { $0.kind == .trashPathPrivileged }
        let permanent = all.filter { $0.kind != .trashPathPrivileged && $0.effectiveDisposition == .delete }
        let trash = all.filter { $0.kind != .trashPathPrivileged && $0.effectiveDisposition != .delete }
        let named = model.removalSteps.filter { !$0.kind.targetIsPath }
        let tool = named.filter { $0.kind == .delegateToolCleanup }
        let records = named.filter { $0.kind != .delegateToolCleanup }
        return [
            ("To the Trash", trash), ("Set aside by the helper", helper), ("Deleted permanently", permanent),
            ("Run by the tool", tool), ("Records", records)
        ]
        .filter { !$0.1.isEmpty }
    }
}

extension RemovalPanel {
    // MARK: - Result

    private func proof(_ result: VerificationResult) -> some View {
        RemovalResultView(result: result, plan: model.plan, groups: model.reviewGroups,
                          spaceExplanation: model.spaceExplanation)
            .transition(.opacity)
    }

    private func outcome(symbol: String, tint: Color, title: String, detail: String) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    /// The one button, which carries the removal's progress and gives way
    /// to Done once the result is in.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .ready = model.phase, let plan = model.plan {
                Text(freed(plan))
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            if isFinished {
                Button(action: close) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    Task { await model.authorize(requesterIdentity: NSUserName()) }
                } label: {
                    HStack(spacing: 8) {
                        if model.phase == .executing {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(buttonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAuthorize)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(20)
    }

    private var buttonTitle: String {
        if isToolRun {
            return model.phase == .executing ? "Running" : "Run"
        }
        return model.phase == .executing ? "Removing" : "Remove"
    }

    /// Zero is a real and common answer: a set of broken links takes no
    /// space, and saying so stops the removal looking like it will do nothing.
    private func freed(_ plan: Plan) -> String {
        if isToolRun {
            return "The tool decides what goes"
        }
        if plan.scanCompleteness?.isComplete == false {
            return "Size not fully measured"
        }
        var consequences: [String] = []
        if plan.trashedBytes > 0 {
            consequences.append("\(ByteText.short(plan.trashedBytes)) to the Trash, recoverable")
        }
        if plan.setAsideBytes > 0 {
            consequences.append("\(ByteText.short(plan.setAsideBytes)) set aside; restore unavailable in Brim")
        }
        if plan.immediatelyFreedBytes > 0 {
            consequences.append("\(ByteText.short(plan.immediatelyFreedBytes)) of files deleted. Free space may differ")
        }
        return consequences.isEmpty ? "Takes no space" : consequences.joined(separator: ". ")
    }

    private var isFinished: Bool {
        switch model.phase {
        case .verified, .appliedButUnverified, .failed: true
        default: false
        }
    }

    private func close() {
        switch model.phase {
        case let .verified(result): onClose(result)
        case .appliedButUnverified:
            onUnverified()
            onClose(nil)
        default: onClose(nil)
        }
    }

    private func helperNotice(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.helperSteps == 1 ? "1 needs Brim's helper" : "\(model.helperSteps) need Brim's helper",
                systemImage: "lock.shield"
            )
            .font(.brimRowTitle)
            .foregroundStyle(Palette.caution)
            Text(problem)
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Turn On") {
                    HelperRoute.turnOn()
                    Task { await checkHelper() }
                }
                .buttonStyle(.bordered)
                Button("Check Again") { Task { await checkHelper() } }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(12)
        .background(Palette.caution.opacity(0.08), in: .rect(cornerRadius: Metrics.rowRadius))
    }

    private func checkHelper() async {
        guard model.helperSteps > 0 else { return }
        helperProblem = await HelperRoute.problem()
    }
}
