import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Apps that have left this Mac and what each one left behind.
///
/// One row per app, named and shown as the app was, with when Brim saw it
/// go. The one action finishes the removal: it opens the same review an
/// uninstall uses, where what is certain is ticked and what is not is
/// shown and left. Traces nobody can be named for sit in one folded
/// section and are never counted.
struct LeftoversView: View {
    @ObservedObject var model: LeftoversModel
    /// The Trash, shared with Home and the Journal because the Trash is one
    /// thing and two watchers would poll it twice.
    @ObservedObject var recovery: RecoveryStatusModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(AppSession.self) private var session
    @State private var review: PlanIntent?
    /// Locations removed while the review was open, for the toast.
    @State private var removedInReview = 0

    /// Under a megabyte, a trace nobody can be named for is not worth a row.
    private static let smallestUnknown: Int64 = 1_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
        .sheet(item: $review) { intent in
            RemovalPanel(
                intent: intent, service: service,
                onRemoved: { paths in
                    removedInReview += paths.count
                    model.forget(paths: paths)
                },
                onClose: { proven in
                    review = nil
                    if let proven { offerPutBack(proven) }
                },
                onUnverified: { Task { await model.load(service: service) } },
                onPhase: { _ in }
            )
            .frame(width: 560, height: 600)
        }
        .task { await model.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .task(id: model.checkedAt) {
            guard model.checkedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            session.visits.acknowledge("leftovers", current: Set(model.all.map(\.id)))
        }
        // Restoring from the Trash puts files back where they were, so
        // their rows belong back in the list.
        .onChange(of: recovery.items) { _, _ in model.reconcileWithDisk() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Removed apps")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            if model.checkedAt != nil {
                Text(summary)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            if model.isScanning {
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
        let groups = model.orphanedGroups
        guard !groups.isEmpty else { return "Nothing left behind" }
        let apps = groups.count == 1 ? "1 app" : "\(groups.count) apps"
        return "\(apps) left \(ByteText.short(groups.reduce(0) { $0 + $1.totalBytes }))"
    }

    // MARK: - List

    private var unknowns: [LeftoverGroup] {
        model.unclaimedGroups.filter { $0.totalBytes >= Self.smallestUnknown }
    }

    private var sections: [ItemGroup<LeftoverGroup>] {
        var sections: [ItemGroup<LeftoverGroup>] = []
        if !model.orphanedGroups.isEmpty {
            sections.append(ItemGroup(id: "removed", title: "Left something behind",
                                      items: model.orphanedGroups.sorted { $0.totalBytes > $1.totalBytes }))
        }
        if !unknowns.isEmpty {
            sections.append(ItemGroup(id: "unknown", title: "Can't tell whose",
                                      items: unknowns.sorted { $0.totalBytes > $1.totalBytes }, startsCollapsed: true))
        }
        return sections
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning, model.all.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if let error = model.errorMessage {
            EmptyState.couldNotRead(error) { Task { await model.load(service: service) } }
        } else if sections.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing left behind",
                       message: "No removed app has left anything on this Mac.")
        } else {
            if model.orphanedGroups.isEmpty { nothingLeft }
            GroupedStacks(
                sections: sections,
                summary: { "\($0.items.count)" },
                inspected: nil,
                inspect: { _ in },
                row: row
            )
            .refreshing(model.isScanning)
        }
    }

    /// Said where the removed apps would be, before the folded unknowns.
    private var nothingLeft: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("No removed app has left anything")
                .font(.brimRowTitle)
                .foregroundStyle(Palette.ink)
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func row(_ group: LeftoverGroup) -> some View {
        let removed = group.category == .orphaned
        let facts = Self.facts(group)
        return HStack(spacing: 12) {
            BrimIcon(source: group.ownerIcon)
                .opacity(removed ? 0.85 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(facts)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)
            .help(group.evidence)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(group.displayName), \(facts)")
            Spacer(minLength: 8)
            Button(removed ? "Finish Removal" : "Review") { open(group) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(model.isScanning)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
    }

    private static func facts(_ group: LeftoverGroup) -> String {
        let places = group.items.count == 1 ? "1 place" : "\(group.items.count) places"
        let size = places + " · " + ByteText.short(group.totalBytes)
        guard let removed = group.removedAt else { return size }
        return "Removed " + removed.formatted(.dateTime.day().month(.abbreviated)) + " · " + size
    }

    // MARK: - Removing

    private func open(_ group: LeftoverGroup) {
        removedInReview = 0
        review = model.removalIntent(for: group, requesterIdentity: NSUserName())
    }

    /// After a removal the check proved: say so, and offer it back.
    private func offerPutBack(_ planId: UUID) {
        let count = removedInReview
        guard count > 0 else { return }
        shell.show(ToastMessage(
            symbol: "checkmark.circle.fill",
            text: count == 1 ? "Moved 1 item to the Trash" : "Moved \(count) items to the Trash",
            actionTitle: "Put Back",
            action: {
                Task {
                    do {
                        try await service.undo(planId: planId)
                        recovery.refreshNow()
                        model.reconcileWithDisk()
                    } catch {
                        shell.show(ToastMessage(symbol: "exclamationmark.triangle.fill", text: "Could not put it back"))
                    }
                }
            }
        ))
    }
}

extension PlanIntent: @retroactive Identifiable {
    public var id: String {
        explicitTargets.map(\.path).joined(separator: "|")
    }
}
