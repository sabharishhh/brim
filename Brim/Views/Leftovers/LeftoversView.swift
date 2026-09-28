import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// What removed software left behind, grouped by what can safely go.
///
/// Stacks of owners on the left, one owner in depth on the right, and the
/// Tray at the bottom holding what is picked. The model keeps the scan and
/// the selection; this page only arranges them.
struct LeftoversView: View {
    @ObservedObject var model: LeftoversModel
    /// The Trash, shared with Home and the Journal because the Trash is one
    /// thing and two watchers would poll it twice.
    @ObservedObject var recovery: RecoveryStatusModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(AppSession.self) private var session
    @SwiftUI.Environment(\.undoManager) private var undoManager
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage("leftovers.grouping") private var grouping = LeftoverGrouping.smart
    @State private var reviewRequest: PlanIntent?
    /// Locations removed while the review was open, for the toast.
    @State private var removedInReview = 0

    var body: some View {
        // Fixed panes rather than an HSplitView: a split view relays out
        // the whole window on every scroll (`CLAUDE.md`).
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                content
            }
            .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
            // The Tray belongs to the list it collects from, so it is
            // centred on this column at any window width rather than on
            // the list and the inspector together.
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: trayContents) }
            // Held still while a review is open: the plan is of what was
            // picked when Review was pressed, and a tick now would not be
            // in it. Dimmed a little so the review reads as the focus.
            .opacity(reviewRequest == nil ? 1 : 0.55)
            .allowsHitTesting(reviewRequest == nil)
            .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: reviewRequest == nil)
            inspector
                .frame(width: 340)
        }
        .task { await model.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        // Seen, a moment after it is on screen, so the new dots are seen
        // before they go.
        .task(id: model.checkedAt) {
            guard model.checkedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                session.visits.acknowledge("leftovers", current: Set(model.all.map(\.id)))
            }
        }
        // Restoring from the Trash puts files back where they were, so
        // their rows belong back in the list.
        .onChange(of: recovery.items) { _, _ in model.reconcileWithDisk() }
        .onAppear { model.keptGroups = keptIDs }
        .onChange(of: keptIDs) { _, kept in model.keptGroups = kept }
        .focusedSceneValue(\.removeSelectedAction, removeSelectedIfPossible)
        .focusedSceneValue(\.selectedItems, SelectedItems(urls: inspectedURLs))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Leftovers")
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
                Picker("Group By", selection: $grouping) {
                    ForEach(LeftoverGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search leftovers")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let groups = model.orphanedGroups + model.unclaimedGroups
        return "\(groups.count) · \(ByteText.short(groups.reduce(0) { $0 + $1.totalBytes }))"
    }

    // MARK: - Stacks

    @ViewBuilder
    private var content: some View {
        if model.isScanning, model.all.isEmpty {
            SkeletonRows()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if let error = model.errorMessage {
            EmptyState.couldNotRead(error) { Task { await model.load(service: service) } }
        } else if model.all.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "Nothing left behind", message: "No leftovers found.")
        } else {
            LeftoverStacks(
                model: model, grouping: grouping, keptIDs: keptIDs, newItems: newItems,
                pick: pick, keep: toggleKeep, changePick: changePick
            )
            // A new grouping is a new order to hold.
            .id(grouping)
            .refreshing(model.isScanning)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let intent = reviewRequest {
            RemovalPanel(
                intent: intent, service: service,
                onRemoved: { paths in
                    // Rows go the moment the check proves them gone, with
                    // the review still open, because that is when it
                    // became true.
                    removedInReview += paths.count
                    model.forget(paths: paths)
                },
                onClose: { proven in
                    reviewRequest = nil
                    if let proven {
                        offerPutBack(proven)
                    }
                },
                onUnverified: { Task { await model.load(service: service) } }
            )
            .id(intent.id)
            .transition(.opacity)
        } else if let group = model.inspected {
            LeftoverInspector(
                group: group,
                isPicked: model.isSelected(group),
                isKept: keptIDs.contains(group.id),
                pick: { pick(group) },
                keep: { toggleKeep(group) }
            )
            .refreshing(model.isScanning)
            // Keyed on the group and a crossfade only, so arrowing through
            // the list does not make the pane swim.
            .id(group.id)
            .transition(.opacity)
            .animation(Motion.resolved(Motion.inspector, reduceMotion: reduceMotion), value: group.id)
        } else {
            PanePlaceholder(symbol: "shippingbox", title: "Select a leftover")
        }
    }

    private var inspectedURLs: [URL] {
        model.inspected?.items.map(\.url) ?? []
    }

    // MARK: - Decisions

    private static let keptPrefix = "leftover:"

    private var keptIDs: Set<String> {
        Set(session.decisions.kept.keys.filter { $0.hasPrefix(Self.keptPrefix) }
            .map { String($0.dropFirst(Self.keptPrefix.count)) })
    }

    private var newItems: Set<String> {
        session.visits.newItems(in: "leftovers", current: Set(model.all.map(\.id)))
    }

    /// Keep or stop keeping, as one step Command-Z can take back.
    private func toggleKeep(_ group: LeftoverGroup) {
        let key = Self.keptPrefix + group.id
        let decisions = session.decisions
        let wasKept = decisions.isKept(key)
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            if wasKept {
                decisions.unkeep([key])
            } else {
                decisions.keep([key])
            }
        }
        registerKeepUndo(key: key, keptNow: !wasKept, name: wasKept ? "Stop Keeping" : "Keep")
        if !wasKept {
            shell.show(ToastMessage(
                symbol: "pin.fill", text: "Kept \(group.displayName)", actionTitle: "Undo",
                action: { [undoManager] in undoManager?.undo() }
            ))
        }
    }

    private func registerKeepUndo(key: String, keptNow: Bool, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: session.decisions) { decisions in
            MainActor.assumeIsolated {
                if keptNow {
                    decisions.unkeep([key])
                } else {
                    decisions.keep([key])
                }
                registerKeepUndo(key: key, keptNow: !keptNow, name: name)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: - Tray

    /// What is ticked, as the window's Tray. The model keeps the
    /// selection; this only describes it.
    private var trayContents: TrayContents? {
        guard !model.selectedItems.isEmpty, reviewRequest == nil else { return nil }
        let blocked = model.blockedSelection.count
        return TrayContents(
            count: model.selectedItems.count, bytes: model.selectedBytes,
            // Not while a rescan is replacing what the Tray points at.
            canReview: model.canRemoveSelection && !model.isScanning,
            note: blocked == 0 ? nil : "\(blocked) need Full Disk Access",
            review: review,
            clear: clearTray
        )
    }

    private var removeSelectedIfPossible: FocusedAction<Void>? {
        guard model.canRemoveSelection else { return nil }
        return FocusedAction(name: "remove leftovers") { _ in review() }
    }

    private func review() {
        removedInReview = 0
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
        }
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

    private func pick(_ group: LeftoverGroup) {
        let adding = !model.isSelected(group)
        changePick(adding ? "Add to Tray" : "Remove from Tray") { model.toggle(group) }
    }

    private func changePick(_ name: String, _ change: () -> Void) {
        let before = model.selection
        change()
        PickUndo.register(undoManager, on: model, name: name, from: before, to: model.selection)
    }

    private func clearTray() {
        changePick("Clear Tray") { model.restoreSelection([]) }
        shell.show(ToastMessage(
            symbol: "tray", text: "Tray cleared", actionTitle: "Undo",
            action: { [undoManager] in undoManager?.undo() }
        ))
    }
}

extension PlanIntent: @retroactive Identifiable {
    public var id: String {
        explicitTargets.map(\.path).joined(separator: "|")
    }
}
