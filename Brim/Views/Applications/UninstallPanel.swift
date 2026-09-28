import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// The deep uninstall, reviewed and proven in the Apps page's right pane.
///
/// Nothing here names a path. The plan is built from the application's
/// identity alone, so what the person sees is what the evidence engine
/// found, and after applying, the panel shows the re-check in place of the
/// button. It used to be a sheet, which hid the page it was about.
struct UninstallPanel: View {
    let application: InstalledApplication
    let service: any BrimServiceProtocol
    /// Uninstall removes the application and everything it wrote. Reset
    /// keeps the application and its licence and removes the state, so
    /// it starts as if new. One sheet for both, because the review and
    /// the approval are identical and only the plan differs.
    var intentType: IntentType = .uninstall
    /// The work is done: the page reads the Mac again.
    let onFinished: () -> Void
    /// The panel is closed, whatever happened.
    let onClose: () -> Void

    @StateObject private var model = UninstallExecutionModel()
    @State private var showingSearchDetails = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: model.phase)
        .onKeyPress(.escape) {
            guard model.phase != .executing else { return .ignored }
            close()
            return .handled
        }
        .task {
            // Identity only — no specific targets. This is the difference
            // between uninstalling an application and tidying a folder.
            await model.prepare(
                intent: PlanIntent(
                    type: intentType,
                    subjectIdentity: application.identity,
                    requesterKind: "ui",
                    requesterIdentity: NSUserName()
                ),
                service: service
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BrimIcon(source: .bundle(application.url), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(isReset ? "Reset" : "Review")
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(application.name)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            RowAction(symbol: "xmark", help: "Close", action: close)
                .disabled(model.phase == .executing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var isFinished: Bool {
        switch model.phase {
        case .verified, .appliedButUnverified, .failed: true
        default: false
        }
    }

    private func close() {
        switch model.phase {
        case .verified, .appliedButUnverified: onFinished()
        default: break
        }
        onClose()
    }

    /// One sheet serves both jobs, and every sentence in it used to be
    /// written for the uninstall. Resetting an application showed a progress
    /// line saying it was being cleared out, finished on "Nothing is left"
    /// about an application that is still installed on purpose, and offered
    /// a button reading "Authorize & Uninstall" that did not uninstall
    /// anything.
    private var isReset: Bool {
        intentType == .reset
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            SkeletonRows(count: 5, showsTick: false)
                .padding(.horizontal, 8)

        case let .failed(reason):
            message(title: "Stopped", detail: reason, isError: true)

        case let .appliedButUnverified(reason):
            message(
                title: isReset ? "Reset, not checked" : "Removed, not checked",
                detail: reason,
                isError: false
            )

        case .executing:
            // The plan stays in view, fixed, while the button says it runs.
            planList.disabled(true)

        case let .verified(result):
            verification(result)

        case .ready:
            if showingSearchDetails, let report = model.plan?.capabilityReport {
                SearchDetailsView(report: report) { showingSearchDetails = false }
            } else {
                planList
            }
        }
    }

    private var planList: some View {
        List {
            if let gaps = model.plan?.scanCompleteness {
                if !gaps.unreadable.isEmpty {
                    Section("Could not read") {
                        ForEach(gaps.unreadable, id: \.self) { path in
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if !gaps.timedOut.isEmpty {
                    Section("Scan timed out") {
                        ForEach(gaps.timedOut, id: \.self) { path in
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            if model.clearsPrivacyGrants || model.clearsRegistrations {
                Section {
                    ReviewHeading(title: "System records")
                    if model.clearsPrivacyGrants {
                        LabeledContent("Privacy permissions", value: "Reset")
                    }
                    if model.clearsRegistrations {
                        LabeledContent("File associations", value: "Remove")
                    }
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
            }

            if !model.reviewGroups.isEmpty {
                Text("Selected (\(model.removalSteps.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.reviewGroups) { group in
                Section {
                    ReviewHeading(title: "\(group.title) (\(group.steps.count))")
                    ForEach(ReviewRun.runs(of: group.steps)) { run in
                        if run.steps.count > 1 {
                            UninstallPlanRow(
                                target: run.folder, evidence: run.steps[0].evidence,
                                bytes: run.steps.reduce(0) { $0 + $1.expectedBytes },
                                disposition: run.steps[0].effectiveDisposition,
                                kind: run.steps[0].kind, tier: run.steps[0].tier, count: run.steps.count
                            )
                        } else {
                            let step = run.steps[0]
                            UninstallPlanRow(
                                target: step.target, evidence: step.evidence,
                                bytes: step.expectedBytes, disposition: step.effectiveDisposition,
                                kind: step.kind, tier: step.tier,
                                selection: model.isTickedByHand(step.target) ? selection(for: step.target) : nil
                            )
                        }
                    }
                }
                .listSectionSeparator(.hidden)
            }

            if !model.offerGroups.isEmpty {
                Text("Also include (\(model.rowsToOffer.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.offerGroups) { group in
                Section {
                    ReviewHeading(title: "\(group.title) (\(group.rows.count))")
                    ForEach(group.rows, id: \.target) { row in
                        UninstallPlanRow(
                            target: row.target, evidence: row.evidence ?? row.reason,
                            bytes: row.sizeBytes ?? 0, disposition: nil,
                            kind: nil, tier: row.tier,
                            selection: selection(for: row.target)
                        )
                    }
                }
                .listSectionSeparator(.hidden)
            }

            StayingSection(items: model.staying)

            if model.plan?.capabilityReport != nil {
                Button("What Brim checked") { showingSearchDetails = true }
                    .buttonStyle(.link)
                    .font(.brimFacts)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func verification(_ result: VerificationResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: result.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.success ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.caution))
                .symbolEffect(.bounce, value: result.success)

            Text(headline(for: result))
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)

            // The proof, not a reassurance: the targets were re-checked after
            // removal and this is what the check found.
            Text(result.success
                ? (isReset ? "App kept, its data cleared" : "Every location checked again")
                : (result.reason ?? "Some of it remains"))
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            if !result.success, !result.remainingPaths.isEmpty {
                let urls = result.remainingPaths.sorted().map { URL(fileURLWithPath: $0) }
                Button(urls.count == 1 ? "Show in Finder" : "Show All in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }

            if let actions = result.followUpActions {
                ForEach(actions, id: \.self) { action in
                    Text(action.sentence)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if result.recoveredBytes > 0 {
                Text("\(ByteText.short(result.recoveredBytes)) freed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if let explanation = model.spaceExplanation {
                Label(explanation, systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundColor(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

private extension UninstallPanel {
    /// One button that carries the work and gives way to Done.
    var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .ready = model.phase, let plan = model.plan {
                if model.isUpdating {
                    Label("Updating", systemImage: "arrow.triangle.2.circlepath")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                } else {
                    Text(freed(plan))
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
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
                .disabled(!model.canAuthorize || showingSearchDetails)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(20)
    }

    var buttonTitle: String {
        switch (isReset, model.phase == .executing) {
        case (true, true): "Resetting"
        case (true, false): "Reset"
        case (false, true): "Removing"
        case (false, false): "Remove"
        }
    }

    /// Where the bytes go, said separately. "Frees 1.19 GB · 1.19 GB
    /// recoverable from the Trash" promised space that only comes back when
    /// the Trash is emptied, for items that were not going to the Trash at
    /// all, and the result then said 6.6 MB freed.
    func freed(_ plan: Plan) -> String {
        let setAside = plan.steps.filter { $0.kind == .trashPathPrivileged }.reduce(0) { $0 + $1.expectedBytes }
        let trashed = plan.trashedBytes - setAside
        let parts = [
            trashed > 0 ? "\(ByteText.short(trashed)) to the Trash" : nil,
            setAside > 0 ? "\(ByteText.short(setAside)) set aside" : nil,
            plan.immediatelyFreedBytes > 0 ? "\(ByteText.short(plan.immediatelyFreedBytes)) freed now" : nil
        ].compactMap(\.self)
        return parts.isEmpty ? "Nothing to free" : parts.joined(separator: " · ")
    }
}

private extension UninstallPanel {
    func selection(for path: String) -> Binding<Bool> {
        Binding(
            get: { model.isTickedByHand(path) },
            set: { ticked in
                Task { await model.setTicked(ticked, path: path) }
            }
        )
    }

    func headline(for result: VerificationResult) -> String {
        guard result.success else { return "Some of it remains" }
        if result.followUpActions?.isEmpty == false {
            return "One more step"
        }
        return isReset ? "Reset" : "Nothing left"
    }

    func message(title: String, detail: String, isError: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundColor(isError ? .red : .primary)
            Text(detail).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// Consecutive steps in one folder, shown as one row once there are more
/// than five of them.
struct ReviewRun: Identifiable {
    let folder: String
    let steps: [Step]
    var id: Int { steps[0].index }

    static func runs(of steps: [Step]) -> [ReviewRun] {
        let byFolder = Dictionary(grouping: steps) { ($0.target as NSString).deletingLastPathComponent }
        return steps.reduce(into: [ReviewRun]()) { runs, step in
            let folder = (step.target as NSString).deletingLastPathComponent
            let siblings = byFolder[folder] ?? []
            if siblings.count > 5 {
                guard !runs.contains(where: { $0.folder == folder && $0.steps.count > 1 }) else { return }
                runs.append(ReviewRun(folder: folder, steps: siblings))
            } else {
                runs.append(ReviewRun(folder: folder, steps: [step]))
            }
        }
    }
}

/// A section's title as its first row. A pinned header draws its own band
/// and rule over the rows beneath it, and regions here are told apart by
/// space and type, never by lines.
struct ReviewHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.brimGroupTitle)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}
