import BrimCore
import BrimPrivileged
import BrimProtocol
import BrimUI
import SwiftUI

/// What your software runs in the background, and what macOS is still being
/// told to run for software that is no longer here.
///
/// This is the surface the whole product grew out of. Remove an app without
/// deregistering it and System Settings goes on listing its background item,
/// often as a bare identifier with no name, and no amount of deleting files
/// clears it.
///
/// Apple's own registrations are not here and there is no switch to add
/// them. They were 1,398 rows of the 1,421 on this Mac, and nothing among
/// them could be removed or was worth reading. `BackgroundModel` holds the
/// measurement.
struct BackgroundView: View {
    @ObservedObject var model: BackgroundModel
    @ObservedObject private var helper: PrivilegedHelperClient
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var inspectedID: String?
    @State private var reviewRequest: PlanIntent?
    @State private var removedInReview = 0
    /// Worked out once per scan: resolving an icon reads the disk.
    @State private var icons: [String: IconSource] = [:]
    /// Each record's file for Finder, by registration id, for the same reason.
    @State private var reveals: [String: URL] = [:]

    init(model: BackgroundModel) {
        self.model = model
        helper = model.helper
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                notices
                content
            }
            .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: trayContents) }
            .opacity(reviewRequest == nil ? 1 : 0.55)
            .allowsHitTesting(reviewRequest == nil)
            .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: reviewRequest == nil)
            inspector
                .frame(width: reviewRequest == nil ? 340 : 440)
        }
        .task { await model.loadIfNeeded(service: service) }
        .task(id: model.revision) {
            icons = Self.icons(for: sections)
            reveals = Self.reveals(for: sections)
        }
        .environment(\.backgroundReveals, reveals)
        .focusedSceneValue(\.removeSelectedAction, removeSelectedIfPossible)
        .focusedSceneValue(\.selectedItems, SelectedItems(urls: inspectedURLs))
    }

    private var sections: [ItemGroup<BackgroundEntry>] {
        BackgroundGrouper.groups(stale: model.stale, clearing: model.clearingItself, live: model.live)
    }

    private var inspectedURLs: [URL] {
        inspected?.group.items.compactMap { reveals[$0.id] } ?? []
    }

    private var inspected: BackgroundEntry? {
        guard let inspectedID else { return nil }
        return sections.lazy.flatMap(\.items).first { $0.id == inspectedID }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Background")
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                if hasData {
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
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search background items")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var hasData: Bool {
        !model.report.registrations.isEmpty
    }

    private var summary: String {
        let running = "\(model.live.count) listed"
        let gone = model.stale.count
        return gone == 0 ? running : "\(running) · \(gone) left over"
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if model.isLoading, !hasData {
            SkeletonRows()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if sections.isEmpty {
            if model.searchText.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "Nothing listed",
                           message: "No application background items.")
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches your search.")
            }
        } else {
            GroupedStacks(
                sections: sections,
                summary: { "\($0.items.count)" },
                revision: model.revision,
                inspected: inspectedID,
                inspect: { inspectedID = $0.id },
                row: row,
                accessory: selectAll
            )
            .refreshing(model.isLoading)
        }
    }

    private func row(_ entry: BackgroundEntry) -> some View {
        BackgroundRow(
            entry: entry,
            icon: icons[entry.id] ?? .symbol(.backgroundItem),
            canPick: model.canSelect(entry.group),
            isPicked: model.isSelected(entry.group),
            needsHelper: entry.state == .gone && !model.canSelect(entry.group)
                && entry.group.stale.contains(where: BackgroundModel.needsTheHelper),
            isInspected: inspectedID == entry.id,
            pick: { model.toggle(entry.group) },
            inspect: { inspectedID = entry.id }
        )
        .contextMenu {
            let urls = entry.group.items.compactMap { reveals[$0.id] }
            if !urls.isEmpty {
                ItemMenuItems(urls: urls)
            }
            if entry.state == .gone {
                Divider()
                Button(model.isSelected(entry.group) ? "Remove from Tray" : "Add to Tray") { model.toggle(entry.group) }
                    .disabled(!model.canSelect(entry.group))
            }
        }
    }

    @ViewBuilder
    private func selectAll(_ section: ItemGroup<BackgroundEntry>) -> some View {
        let pickable = section.items.filter { $0.state == .gone && model.canSelect($0.group) }
        if !pickable.isEmpty {
            let allPicked = pickable.allSatisfy { model.isSelected($0.group) }
            Button(allPicked ? "Deselect All" : "Select All") {
                for entry in pickable where model.isSelected(entry.group) == allPicked {
                    model.toggle(entry.group)
                }
            }
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let intent = reviewRequest {
            RemovalPanel(
                intent: intent, service: service,
                onRemoved: { paths in
                    removedInReview += paths.count
                    model.forget(paths: paths)
                },
                onClose: { proven in
                    reviewRequest = nil
                    if let proven {
                        offerPutBack(proven.planId)
                    }
                },
                onUnverified: { Task { await model.load(service: service) } }
            )
            .id(intent.id)
            .transition(.opacity)
        } else if let entry = inspected {
            BackgroundInspector(
                entry: entry,
                icon: icons[entry.id] ?? .symbol(.backgroundItem),
                canPick: model.canSelect(entry.group),
                isPicked: model.isSelected(entry.group),
                helperIsReady: helper.state.canRemove,
                pick: { model.toggle(entry.group) }
            )
            .refreshing(model.isLoading)
            .id(entry.id)
            .transition(.opacity)
            .animation(Motion.resolved(Motion.inspector, reduceMotion: reduceMotion), value: entry.id)
        } else {
            PanePlaceholder(symbol: "gearshape.2", title: "Select an item")
        }
    }

    private static func reveals(for sections: [ItemGroup<BackgroundEntry>]) -> [String: URL] {
        var reveals: [String: URL] = [:]
        for item in sections.flatMap(\.items).flatMap(\.group.items) {
            reveals[item.id] = item.revealableURL
        }
        return reveals
    }

    private static func icons(for sections: [ItemGroup<BackgroundEntry>]) -> [String: IconSource] {
        var icons: [String: IconSource] = [:]
        for entry in sections.flatMap(\.items) {
            icons[entry.id] = entry.icon
        }
        return icons
    }
}

extension BackgroundView {
    // MARK: - Notices

    /// What could not be read, and what needs the helper. Only genuine
    /// gaps: a surface left alone on purpose is not a fault and gets nothing.
    @ViewBuilder
    private var notices: some View {
        let faults = model.faults
        let waiting = !model.waitingOnHelper.isEmpty && !helper.state.canRemove
        if !faults.isEmpty || waiting {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(faults, id: \.kind) { gap in
                    Notice(
                        symbol: "eye.slash", title: "\(gap.kind.displayName)s not read",
                        detail: gap.limitation,
                        actionTitle: gap.isFixableByTheUser ? "Open Settings" : nil,
                        action: FullDiskAccess.openSettings
                    )
                }
                if waiting {
                    helperNotice
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    /// Offered only when there is something it would do. A standing
    /// invitation to install a root daemon on a Mac with nothing for it to
    /// remove is not a thing to put in front of anybody.
    private var helperNotice: some View {
        let count = model.waitingOnHelper.count
        let title = count == 1 ? "1 needs Brim's helper" : "\(count) need Brim's helper"
        return Group {
            switch helper.state {
            case .waitingForApproval:
                Notice(
                    symbol: "key.horizontal", title: title, detail: "Allow it in Login Items",
                    actionTitle: "Open Settings", action: helper.openSettings
                )
            case let .unavailable(why):
                Notice(symbol: "key.horizontal", title: title, detail: why)
            case .stale:
                Notice(symbol: "key.horizontal", title: title, detail: "Replaced with this version. Starts next time.")
            default:
                Notice(
                    symbol: "key.horizontal", title: title,
                    detail: "Sets job files aside. Brim has no restore action for them.",
                    actionTitle: "Set Up", action: helper.install
                )
            }
        }
        .onAppear { helper.refresh() }
    }

    // MARK: - Tray

    private var trayContents: TrayContents? {
        let count = model.selectedItems.count
        guard count > 0, reviewRequest == nil else { return nil }
        return TrayContents(
            count: count, bytes: nil,
            canReview: !model.isLoading,
            note: model.selectionUsesHelper ? "Some use Brim's helper" : nil,
            review: review,
            clear: { model.selection = [] }
        )
    }

    private var removeSelectedIfPossible: FocusedAction<Void>? {
        guard model.canRemoveSelection else { return nil }
        return FocusedAction(name: "remove background jobs") { _ in review() }
    }

    private func review() {
        removedInReview = 0
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
        }
    }

    private func offerPutBack(_ planId: UUID) {
        let count = removedInReview
        guard count > 0 else { return }
        Task {
            var toast = ToastMessage(
                symbol: "checkmark.circle.fill",
                text: count == 1 ? "Removed 1 job" : "Removed \(count) jobs"
            )
            if await (try? service.recoverableItems())?.contains(where: { $0.planId == planId }) == true {
                toast.actionTitle = "Put Back"
                toast.action = {
                    Task {
                        do {
                            try await service.undo(planId: planId)
                            await model.load(service: service)
                        } catch {
                            shell.show(ToastMessage(
                                symbol: "exclamationmark.triangle.fill",
                                text: "Could not put it back"
                            ))
                        }
                    }
                }
            }
            shell.show(toast)
        }
    }
}

/// A one-line note above a list: what is missing, and the one thing that
/// fixes it.
struct Notice: View {
    let symbol: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Palette.caution.opacity(0.08), in: .rect(cornerRadius: Metrics.rowRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
