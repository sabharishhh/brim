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
                    type: .uninstall,
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
            // The application is the subject. "Review" above its name read
            // as the name of something, and that this is a review is what
            // the panel itself shows.
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .monospacedDigit()
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

    /// What the panel is doing, in a few words.
    private var subtitle: String {
        switch model.phase {
        case .preparing: return "Checking"
        case .executing: return "Removing"
        case .verified, .appliedButUnverified: return "Removed"
        case .failed: return "Stopped"
        case .ready:
            let steps = model.removalSteps
            let bytes = steps.reduce(0) { $0 + $1.expectedBytes }
            let count = steps.count == 1 ? "1 item" : "\(steps.count.formatted()) items"
            return "\(count) · \(ByteText.short(bytes))"
        }
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
                title: "Removed, not checked",
                detail: reason,
                isError: false
            )

        case let .verified(result):
            verification(result)

        // One branch for waiting and running, so it is one list that
        // becomes disabled. As two branches they were two lists, and the
        // change of phase cross-faded them: for a moment both were drawn,
        // row over row.
        case .ready, .executing:
            if model.phase == .ready, showingSearchDetails, let report = model.plan?.capabilityReport {
                SearchDetailsView(report: report) { showingSearchDetails = false }
            } else {
                planList.disabled(model.phase == .executing)
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
                    ReviewHeading(title: "System records", isFirst: true)
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

            ForEach(model.reviewGroups) { group in
                Section {
                    ReviewHeading(title: group.title, count: group.steps.count,
                                  bytes: group.steps.reduce(0) { $0 + $1.expectedBytes })
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
                Text("You can also include")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 22)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.offerGroups) { group in
                Section {
                    ReviewHeading(title: group.title, count: group.rows.count,
                                  bytes: group.rows.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
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
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func verification(_ result: VerificationResult) -> some View {
        RemovalResultView(result: result, plan: model.plan, groups: model.reviewGroups,
                          spaceExplanation: model.spaceExplanation)
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
                        if model.phase == .executing || model.phase == .preparing {
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

    /// Says what the button is waiting for. WhatsApp's review took forty
    /// seconds, and a Remove button that could not be pressed yet looked
    /// like one that would not work.
    var buttonTitle: String {
        switch model.phase {
        case .preparing: "Checking"
        case .executing: "Removing"
        default: model.isUpdating ? "Updating" : "Remove"
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
    var id: Int {
        steps[0].index
    }

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
    var count: Int?
    var bytes: Int64?
    var isFirst = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            if let count {
                Text([count.formatted(), bytes.map { ByteText.short($0) }].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        // Space is what separates one group from the next.
        .padding(.top, isFirst ? 2 : 16)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
