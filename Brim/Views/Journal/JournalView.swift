import BrimCore
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
    @State private var groups: [ItemGroup<JournalEntry>] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.errorMessage {
                Notice(
                    symbol: "exclamationmark.triangle", title: "Could not put it back", detail: message,
                    actionTitle: "Dismiss", action: { model.errorMessage = nil }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
            content
        }
        .task { await model.load(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        // Whether something can be put back changes when the Trash does.
        .task { await recovery.start(service: service) }
        .onChange(of: recovery.items) { _, _ in
            Task { await model.reload() }
        }
        .task(id: Signature(records: model.records, apps: applications.applications.count)) {
            let entries = JournalTimeline.entries(records: model.records, applications: applications.applications)
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                groups = JournalTimeline.groups(entries)
            }
        }
    }

    /// What the timeline is rebuilt on.
    private struct Signature: Equatable {
        let records: [RemovalRecord]
        let apps: Int
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Journal")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
                .pageMorph("page.journal")
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
        .padding(.horizontal, 20)
        .padding(.top, 16)
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
                        ForEach(group.items) { entry in
                            JournalRow(
                                entry: entry,
                                isPuttingBack: isPuttingBack(entry),
                                putBack: { putBack(entry) }
                            )
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                            .transition(.brimRow(reduceMotion: reduceMotion))
                        }
                    } header: {
                        Text(group.title)
                            .font(.brimDayHeader)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 24)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func isPuttingBack(_ entry: JournalEntry) -> Bool {
        guard case let .removed(record) = entry.event else { return false }
        return model.undoingPlanIds.contains(record.id)
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
    let putBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon, badge: isRemoval ? .removed : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(facts)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing
            Text(entry.time)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
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
            return .bundle(url)
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
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Putting back")
            } else if record.canUndo {
                // Only where it would do something: a disabled button on
                // every row is thirty-nine controls that do nothing.
                Button("Put Back", action: putBack)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else if let reason = record.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private var spoken: String {
        switch entry.event {
        case .installed: "\(entry.name), installed, \(entry.time)"
        case let .removed(record): "\(record.spoken) \(entry.time)"
        }
    }
}
