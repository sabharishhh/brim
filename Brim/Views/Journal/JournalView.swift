import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// What happened on this Mac, newest first: what Brim removed and whether
/// it can still be put back, and what was installed.
///
/// Installs come only from snapshots. An app that was here the first time
/// Brim looked has no install to show, and Spotlight's date added moves
/// on every update, so it cannot stand in.
struct JournalView: View {
    @ObservedObject var model: RemovalHistoryModel
    @ObservedObject var recovery: RecoveryStatusModel
    @ObservedObject var applications: ApplicationsModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Built when the records or the apps change, not while drawing.
    @State private var checkedResult: VerificationResult?
    @State private var checkedPlan: Plan?
    @State private var checkingPlanID: UUID?
    @State private var checkError = ""
    @State private var showsCheckError = false
    @State private var groups: [ItemGroup<JournalEntry>] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            // A Put Back's outcome is shown beside its record, once, rather
            // than in a banner above a list the person has scrolled.
            content
        }
        .sheet(item: $checkedResult) { result in
            RemovalVerificationSheet(result: result, plan: checkedPlan)
        }
        .alert("Could not check removal", isPresented: $showsCheckError) {
            Button("OK", role: .cancel) {}
        } message: { Text(checkError) }
        .task { await model.load(service: service) }
        // Listing the apps writes the snapshot an install is read from.
        .task {
            await applications.loadIfNeeded(service: service)
            await model.reload()
        }
        // Whether something can be put back changes when the Trash does.
        .task { await recovery.start(service: service) }
        .onChange(of: recovery.items) { _, _ in
            Task { await model.reload() }
        }
        .task(id: Signature(model.records, installs: model.installs.count)) {
            let entries = JournalTimeline.entries(records: model.records, installs: model.installs)
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                groups = JournalTimeline.groups(entries)
            }
        }
    }

    /// What the timeline is rebuilt on: which removals, whether each can
    /// still be put back, and how many installs. Not the records themselves,
    /// whose equality compares every step of every plan on each update.
    private struct Signature: Equatable {
        let records: [UUID]
        let putBack: [Bool]
        let installs: Int

        init(_ records: [RemovalRecord], installs: Int) {
            self.records = records.map(\.id)
            putBack = records.map(\.canUndo)
            self.installs = installs
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Journal")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            if !model.records.isEmpty {
                Text(summary)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let removed = "\(model.records.count) removed"
        let back = model.records.filter(\.canUndo).count
        return back == 0 ? removed : "\(removed) · \(back) can be put back"
    }

    // MARK: - Timeline

    @ViewBuilder
    private var content: some View {
        if model.isLoading, groups.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if groups.isEmpty {
            EmptyState(symbol: "book.closed", title: "Nothing yet", message: "Removals and installs appear here.")
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        // The group's title as its first row, not a pinned header:
                        // a pinned header is drawn on its own band with a rule under it.
                        Group {
                            Text(group.title)
                                .font(.brimDayHeader)
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 24)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                        ForEach(group.items) { entry in
                            JournalRow(
                                entry: entry,
                                isPuttingBack: isPuttingBack(entry),
                                outcome: outcome(entry),
                                putBack: { putBack(entry) }
                            )
                            .contextMenu {
                                if case let .removed(record) = entry.event {
                                    Button("Check removal", systemImage: "arrow.clockwise") {
                                        recheck(record.plan)
                                    }
                                    .disabled(checkingPlanID != nil)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                            .transition(.brimRow(reduceMotion: reduceMotion))
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
                ListBottomSpacing()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func recheck(_ plan: Plan) {
        guard checkingPlanID == nil else { return }
        checkingPlanID = plan.planId
        Task {
            defer { checkingPlanID = nil }
            do {
                let result = try await service.verify(planId: plan.planId)
                checkedPlan = plan
                checkedResult = result
            } catch {
                checkError = error.localizedDescription
                showsCheckError = true
            }
        }
    }

    private func isPuttingBack(_ entry: JournalEntry) -> Bool {
        guard case let .removed(record) = entry.event else { return false }
        return model.undoingPlanIds.contains(record.id)
    }

    private func outcome(_ entry: JournalEntry) -> RemovalHistoryModel.PutBackOutcome? {
        guard case let .removed(record) = entry.event else { return nil }
        return model.putBackOutcomes[record.id]
    }

    private func putBack(_ entry: JournalEntry) {
        guard case let .removed(record) = entry.event else { return }
        Task { await model.undo(record) }
    }
}

/// One event: the app's icon, what happened, and when.
private struct JournalRow: View {
    let entry: JournalEntry
    let isPuttingBack: Bool
    let outcome: RemovalHistoryModel.PutBackOutcome?
    let putBack: () -> Void
    @State private var showsFailure = false
    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon, size: Metrics.rowIcon(compact: compact), badge: isRemoval ? .removed : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(facts)
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            // Reserved width, so Put Back, its progress and its outcome take
            // turns in one place and the time beside them never moves.
            trailing
                .frame(minWidth: 120, alignment: .trailing)
            Text(entry.time)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    private var isRemoval: Bool {
        if case .removed = entry.event {
            return true
        }
        return false
    }

    /// The app's own icon while it is here, the saved one once it is gone,
    /// and a folder for a removal that was not one app.
    private var icon: IconSource {
        switch entry.event {
        case let .installed(url):
            if let url, entry.isPresent {
                return .bundle(url)
            }
            guard let bundleID = entry.bundleID, IconMemory.standard.has(bundleID) else {
                return .monogram(Monogram(name: entry.name))
            }
            return .remembered(bundleID: bundleID)
        case .removed:
            guard let bundleID = entry.bundleID, IconMemory.standard.has(bundleID) else {
                return entry.bundleID == nil ? .symbol(.folder) : .monogram(Monogram(name: entry.name))
            }
            return .remembered(bundleID: bundleID)
        }
    }

    private var facts: String {
        switch entry.event {
        case .installed:
            return "Installed"
        case let .removed(record):
            let items = record.itemCount == 1 ? "1 item" : "\(record.itemCount) items"
            // Broken links take no space, and "Empty" beside a count of
            // items reads as though nothing was there.
            guard record.bytes > 0 else { return "Removed · \(items)" }
            return "Removed · \(items) · \(ByteText.short(record.bytes))"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case let .removed(record) = entry.event {
            if isPuttingBack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Putting back").font(.caption).foregroundStyle(Palette.inkSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Putting back")
            } else if outcome == .restored {
                // What actually happened, in place of the button: the files
                // are back where they were.
                Label("Put back", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary, Palette.success)
            } else if case let .failed(reason) = outcome {
                Button {
                    showsFailure = true
                } label: {
                    Label("Could not put back", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.inkSecondary, Palette.caution)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(reason)
                .accessibilityHint("Shows why")
                .popover(isPresented: $showsFailure) {
                    Text(reason)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding()
                        .frame(width: 300, alignment: .leading)
                }
            } else if record.canUndo {
                // Only where it would do something: a disabled button on
                // every row is thirty-nine controls that do nothing.
                Button("Put Back", action: putBack)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else if let reason = record.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One sentence for the row, so a reader hears one event rather than
    /// four fragments. Put Back, where there is one, stays its own button.
    private var spoken: String {
        switch entry.event {
        case .installed:
            return "\(entry.name), installed, \(entry.time)"
        case let .removed(record):
            let state = switch outcome {
            case .restored: "put back"
            case let .failed(reason): "could not put back. \(reason)"
            case nil: record.canUndo ? "can be put back" : (record.unavailableReason ?? "")
            }
            return [entry.name, facts, state, entry.time].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}
