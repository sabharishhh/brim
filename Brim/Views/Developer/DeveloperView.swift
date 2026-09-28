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

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                content
            }
            .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: trayContents) }
            .opacity(reviewRequest == nil ? 1 : 0.55)
            .allowsHitTesting(reviewRequest == nil)
            .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: reviewRequest == nil)
            Divider()
            inspector
                .frame(width: reviewRequest == nil ? 340 : 440)
                .background(Palette.surface.opacity(0.5))
        }
        .task { await model.loadIfNeeded(service: service) }
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
                .pageMorph("page.developer")
            if !model.caches.isEmpty {
                Text("\(model.caches.count) · \(ByteText.short(model.totalBytes))")
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
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if model.isScanning, model.caches.isEmpty {
            SkeletonRows()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if model.caches.isEmpty {
            EmptyState(symbol: "hammer", title: "No build caches", message: "Nothing from Xcode, npm, Go or the rest.")
        } else {
            GroupedStacks(
                sections: DeveloperCache.sections(model.caches),
                summary: { section in
                    "\(section.items.count) · \(ByteText.short(section.items.reduce(0) { $0 + $1.sizeBytes }))"
                },
                inspected: inspectedID,
                inspect: { inspectedID = $0.id },
                row: row,
                accessory: selectAll
            )
            .refreshing(model.isScanning)
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
                    if proven != nil {
                        shell.show(ToastMessage(symbol: "checkmark.circle.fill", text: "Caches cleared"))
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
                cleanUp: { cleanUp(cache) }
            )
            .refreshing(model.isScanning)
            .id(cache.id)
            .transition(.opacity)
            .animation(Motion.resolved(Motion.inspector, reduceMotion: reduceMotion), value: cache.id)
        } else {
            PanePlaceholder(symbol: "hammer", title: "Select a cache")
        }
    }

    // MARK: - Removal

    private var trayContents: TrayContents? {
        guard model.canRemove, reviewRequest == nil else { return nil }
        return TrayContents(
            count: model.selection.count, bytes: model.selectedBytes,
            canReview: !model.isScanning,
            review: review,
            clear: { model.clearSelection() }
        )
    }

    private var removeSelectedIfPossible: FocusedAction<Void>? {
        guard model.canRemove else { return nil }
        return FocusedAction(name: "remove build caches") { _ in review() }
    }

    private func review() {
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            reviewPlan = nil
            reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
        }
    }

    /// The tool's own command, planned by the service and reviewed like any
    /// other removal before it runs.
    private func cleanUp(_ cache: DeveloperCache) {
        guard let id = cache.cleanupID, let displayed = cache.cleanupCommand else { return }
        Task {
            do {
                let plan = try await service.planToolCleanup(id: id, displayed: displayed)
                withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                    reviewPlan = plan
                    reviewRequest = plan.intent
                }
            } catch {
                shell.show(ToastMessage(symbol: "exclamationmark.triangle.fill", text: "Could not plan the cleanup"))
            }
        }
    }
}
