import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Build caches, usually the largest reclaimable thing on a developer's Mac
/// and the least visible.
///
/// Grouped by what clearing each one costs rather than by size, because
/// that is the question. Clearing Xcode's derived data costs one slow
/// build; clearing the simulator device set loses every simulator you have
/// set up. Brim lists only caches it has been taught about and leaves
/// anything it does not recognise alone.
struct DeveloperView: View {
    @ObservedObject var model: DeveloperModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var inspectedID: String?
    @State private var reviewRequest: PlanIntent?
    /// The tool's own cleanup, already planned by the service.
    @State private var reviewPlan: Plan?
    @State private var cleanupPlanningTask: Task<Void, Never>?
    @State private var cleanupPlanningGeneration = UUID()

    /// The floating pane's Close in a narrow window.
    private func closeInspector() {
        inspectedID = nil
    }

    var body: some View {
        AdaptivePanes(
            detailWidth: reviewRequest == nil ? 340 : 440,
            hasDetail: reviewRequest != nil || inspectedID != nil,
            isReviewing: reviewRequest != nil,
            close: closeInspector
        ) {
            VStack(spacing: 0) {
                header
                scanScope
                content
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: trayContents) }
            .opacity(reviewRequest == nil ? 1 : 0.55)
            .allowsHitTesting(reviewRequest == nil)
            .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: reviewRequest == nil)
        } detail: {
            inspector
        }
        .task { await model.loadIfNeeded(service: service) }
        .onDisappear {
            cancelCleanupPlanning()
            model.cancelScan()
        }
        .onChange(of: model.isScanning) { _, scanning in
            if scanning {
                cancelCleanupPlanning()
            }
        }
        .focusedSceneValue(\.removeSelectedAction, removeSelectedIfPossible)
        .focusedSceneValue(\.selectedItems, SelectedItems(urls: inspected.map { [$0.url] } ?? []))
    }

    private var inspected: DeveloperCache? {
        model.caches.first { $0.id == inspectedID }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Developer")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            if !model.caches.isEmpty {
                Text("\(model.visibleCaches.count) · \(DeveloperModel.sizeSummary(model.visibleCaches))")
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
            if model.isScanning {
                Button("Stop", action: model.cancelScan)
            } else {
                Button("Scan Again", systemImage: "arrow.clockwise") {
                    Task { await model.load(service: service) }
                }
                .labelStyle(.iconOnly)
                .help("Scan again")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - List

    private var scanScope: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker("Show", selection: $model.ageFilter) {
                    ForEach(DeveloperAgeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 250, alignment: .leading)
                Spacer()
                if !model.excludedFolders.isEmpty {
                    Button("Reset Exclusions") {
                        cancelCleanupPlanning()
                        model.resetExclusions()
                        Task { await model.load(service: service) }
                    }
                }
            }
            if model.scanWasCancelled {
                Text("Scan stopped. Some sizes may still be unavailable.")
            }
            if !model.excludedFolders.isEmpty {
                Text("\(model.excludedFolders.count) folders kept out of cleanup.")
            }
            if model.selectedOutsideFilter > 0 {
                Text("\(model.selectedOutsideFilter) selected items are outside this filter.")
            }
        }
        .font(.brimFacts)
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning, model.caches.isEmpty {
            SkeletonRows()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if model.caches.isEmpty, model.excludedFolders.isEmpty {
            EmptyState(symbol: "hammer", title: "No build caches", message: "Nothing from Xcode, npm, Go or the rest.")
        } else if model.visibleCaches.isEmpty {
            EmptyState(symbol: "line.3.horizontal.decrease", title: "No artifacts in this view",
                       message: "Change the age filter or reset folder exclusions to show more.")
        } else {
            GroupedStacks(
                sections: DeveloperCache.sections(model.visibleCaches),
                summary: { section in
                    "\(section.items.count) · \(DeveloperModel.sizeSummary(section.items))"
                },
                inspected: inspectedID,
                inspect: { inspectedID = $0.id },
                row: row,
                accessory: selectAll
            )
        }
    }

    private func row(_ cache: DeveloperCache) -> some View {
        DeveloperRow(
            cache: cache, isPicked: model.isSelected(cache), isInspected: inspectedID == cache.id,
            pick: { model.toggle(cache) }, inspect: { inspectedID = cache.id }
        )
        .contextMenu {
            ItemMenuItems(urls: [cache.url])
            if cache.cost.isBrimRemovable {
                Divider()
                Button(model.isSelected(cache) ? "Remove from Tray" : "Add to Tray") { model.toggle(cache) }
            }
            Divider()
            Button("Exclude This Folder") {
                cancelCleanupPlanning()
                model.exclude(cache.url)
                Task { await model.load(service: service) }
            }
        }
    }

    @ViewBuilder
    private func selectAll(_ section: ItemGroup<DeveloperCache>) -> some View {
        let pickable = section.items.filter(\.cost.isBrimRemovable)
        if !pickable.isEmpty {
            let allPicked = pickable.allSatisfy(model.isSelected)
            Button(allPicked ? "Deselect All" : "Select All") {
                for cache in pickable where model.isSelected(cache) == allPicked {
                    model.toggle(cache)
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
                onRemoved: { _ in },
                onClose: { proven in
                    reviewRequest = nil
                    reviewPlan = nil
                    // Sizes change when a cache goes, and a tool's own
                    // command may clear more than the one folder.
                    Task { await model.load(service: service) }
                    if proven?.success == true {
                        let message = intent.type == .toolCleanup
                            ? "Cleanup command completed" : "Selected items removed"
                        shell.show(ToastMessage(symbol: "checkmark.circle.fill", text: message))
                    }
                },
                onUnverified: {},
                plan: reviewPlan
            )
            .id(intent.id)
            .transition(.opacity)
        } else if let cache = inspected {
            DeveloperInspector(
                cache: cache, isPicked: model.isSelected(cache),
                pick: { model.toggle(cache) },
                cleanUp: { cleanUp(cache) },
                canCleanUp: !model.isScanning && cleanupPlanningTask == nil
            )
            .id(cache.id)
            .transition(.opacity)
            .animation(Motion.resolved(Motion.inspector, reduceMotion: reduceMotion), value: cache.id)
        } else {
            PanePlaceholder(symbol: "hammer", title: "Select a cache")
        }
    }
}

private extension DeveloperView {
    // MARK: - Removal

    var trayContents: TrayContents? {
        guard model.canRemove, reviewRequest == nil else { return nil }
        return TrayContents(
            count: model.selectedCount, bytes: model.selectedBytes,
            canReview: !model.isScanning,
            review: review,
            clear: { model.clearSelection() }
        )
    }

    var removeSelectedIfPossible: FocusedAction<Void>? {
        guard model.canRemove else { return nil }
        return FocusedAction(name: "remove build caches") { _ in review() }
    }

    func review() {
        guard !model.isScanning else { return }
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            reviewPlan = nil
            reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
        }
    }

    /// The tool's own command, planned by the service and reviewed like any
    /// other removal before it runs.
    func cleanUp(_ cache: DeveloperCache) {
        guard let id = cache.cleanupID, !model.isScanning,
              reviewRequest == nil, cleanupPlanningTask == nil else { return }
        let generation = UUID()
        cleanupPlanningGeneration = generation
        let exclusions = model.excludedFolders
        cleanupPlanningTask = Task {
            defer {
                if cleanupPlanningGeneration == generation {
                    cleanupPlanningTask = nil
                }
            }
            do {
                let plan: Plan = if id == "homebrew.cleanup" {
                    try await service.planHomebrewDownloads(
                        cachePath: cache.url,
                        excluding: exclusions.sorted { $0.path < $1.path }
                    )
                } else {
                    try await service.planToolCleanup(id: id, cachePath: cache.url)
                }
                guard !Task.isCancelled, cleanupPlanningGeneration == generation,
                      !model.isScanning, model.excludedFolders == exclusions,
                      model.caches.contains(where: { $0.id == cache.id && $0.url == cache.url }) else { return }
                withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                    reviewPlan = plan
                    reviewRequest = plan.intent
                }
            } catch {
                guard !Task.isCancelled, cleanupPlanningGeneration == generation else { return }
                shell.show(ToastMessage(symbol: "exclamationmark.triangle.fill", text: error.localizedDescription))
            }
        }
    }

    func cancelCleanupPlanning() {
        cleanupPlanningGeneration = UUID()
        cleanupPlanningTask?.cancel()
        cleanupPlanningTask = nil
    }
}
