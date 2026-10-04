import BrimCore
import BrimUI
import SwiftUI
import SystemConfiguration

/// The first page: this Mac at a glance, then in depth one click away.
///
/// The Mac's name, cards for Space, Leftovers, Background and Developer,
/// recently installed apps, and a place to drop an app. Short phrases only, and no
/// number that was not measured: every figure waits for its scan.
struct HomeView: View {
    // Each model observed directly. Nested `ObservableObject`s do not
    // propagate, so observing `SectionModels` alone would never redraw.
    @ObservedObject private var leftovers: LeftoversModel
    @ObservedObject private var applications: ApplicationsModel
    @ObservedObject private var recovery: RecoveryStatusModel
    @ObservedObject private var fullDiskAccess: FullDiskAccessModel
    @ObservedObject private var background: BackgroundModel
    @ObservedObject private var storage: StorageModel
    @ObservedObject private var developer: DeveloperModel
    @ObservedObject private var updates: UpdatesModel
    private let models: SectionModels

    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell

    init(models: SectionModels) {
        self.models = models
        leftovers = models.leftovers
        applications = models.applications
        recovery = models.recovery
        fullDiskAccess = models.fullDiskAccess
        background = models.background
        storage = models.storage
        developer = models.developer
        updates = models.updates
    }

    var body: some View {
        ScrollView {
            // Centred with spacers, not `.frame(maxWidth: .infinity)`, which
            // reports the content as willing to take any width and once made
            // the window open at half the display.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 20) {
                    header
                    DropWell { models.openApplication(from: $0, shell: shell) }
                    if !fullDiskAccess.isGranted {
                        accessNote
                    }
                    if recovery.isAvailable, !recovery.isEmpty {
                        recoveryNote
                    }
                    spaceCard
                    HStack(alignment: .top, spacing: 16) {
                        leftoversCard
                        backgroundCard
                        developerCard
                        updatesCard
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let recent = applications.recentlyInstalled(now: context.date)
                        if !recent.isEmpty {
                            recentCard(recent)
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(Metrics.pagePadding)
                Spacer(minLength: 0)
            }
        }
        .task { await leftovers.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .task { await background.loadIfNeeded(service: service) }
        .task { await storage.loadIfNeeded(service: service) }
        .task { await developer.loadIfNeeded(service: service) }
        .task { await updates.loadIfNeeded(service: service) }
        .onAppear { fullDiskAccess.startObserving() }
    }

    // MARK: - Header

    /// The Mac's name and how fresh the numbers are. No sentence: the
    /// cards say what matters in a few words each.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.macName)
                .font(.brimHeadline)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            FreshnessLabel(freshness: freshness)
        }
    }

    /// The computer's own name, as Sharing settings has it. Read once:
    /// `Host.current()` can wait on the network to answer the same thing.
    private static let macName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"

    private var freshness: Freshness {
        if leftovers.isScanning {
            return .checking
        }
        if let checkedAt = leftovers.checkedAt {
            return .checked(checkedAt)
        }
        if let error = leftovers.errorMessage {
            return .failed(error)
        }
        return .notChecked
    }

    // MARK: - Notes

    private var accessNote: some View {
        HomeNote(
            symbol: "lock", tint: Palette.caution,
            title: "Full Disk Access is off",
            detail: "Most of Library is out of sight, so counts are low.",
            actionTitle: "Open Settings"
        ) { FullDiskAccess.openSettings() }
    }

    private var recoveryNote: some View {
        let count = recovery.items.count
        return HomeNote(
            symbol: "arrow.uturn.backward", tint: .accentColor,
            title: count == 1 ? "1 removal can be put back" : "\(count) removals can be put back",
            detail: recovery.totalBytes > 0 ? "\(ByteText.short(recovery.totalBytes)) in the Trash"
                : "Ready to put back",
            actionTitle: "Open Journal"
        ) { shell.go(to: .journal) }
    }

    // MARK: - Cards

    private var spaceCard: some View {
        let volume = storage.startupVolume
        return StatCard(
            title: "Space", symbol: "internaldrive",
            figure: volume.map { ByteText.short($0.freeRightNow) + " free" } ?? "…",
            status: volume == nil ? .checking : .neutral,
            phrase: volume.map { "of \(ByteText.short($0.capacity)) on \($0.name)" } ?? "Checking",
            isRefreshing: storage.isLoading && volume != nil
        ) {
            if let volume {
                // Three facts, never added into one: what is used, what
                // macOS will release when it needs to, and what is free.
                MeterBar(segments: [
                    MeterSegment(label: "Used", value: volume.used, color: Palette.hue(1)),
                    MeterSegment(
                        label: "Held by macOS", value: volume.reclaimableByTheSystem,
                        color: Palette.hue(1).opacity(0.4)
                    ),
                    MeterSegment(label: "Free", value: volume.freeRightNow, color: Palette.well)
                ])
            }
        } action: { shell.go(to: .space) }
    }

    private var leftoversCard: some View {
        let groups = leftovers.orphanedGroups
        let checked = leftovers.checkedAt != nil
        let failed = leftovers.errorMessage != nil
        let unclaimed = leftovers.unclaimedGroupsForReview.count
        let size = HomeRemnantsSize(groups: groups, unclaimed: unclaimed)
        let summary = HomeStatus.leftovers(.init(
            removedApps: leftovers.orphanedGroups.count, unclaimed: unclaimed,
            hasChecked: checked, canSeeLibrary: fullDiskAccess.isGranted
        ))
        let rebuilds = groups.reduce(0) { $0 + $1.regeneratedBytes }
        let data = groups.reduce(0) { $0 + $1.meaningfulBytes }
        return StatCard(
            title: "Remnants", symbol: "app.dashed",
            figure: failed ? "Unavailable" : (checked ? size.figure : "…"),
            status: failed || !size.isComplete ? .partial : summary.status,
            phrase: failed ? "Could not check remnants"
                : (size.isComplete ? summary.phrase : "Some locations could not be measured"),
            isRefreshing: leftovers.isScanning && checked
        ) {
            if checked, size.isComplete, rebuilds + data > 0 {
                MeterBar(segments: [
                    MeterSegment(label: "Data", value: data, color: Palette.hue(5)),
                    MeterSegment(label: "Rebuilds", value: rebuilds, color: Palette.hue(0))
                ])
            }
        } action: { shell.go(to: .leftovers) }
    }

    private var backgroundCard: some View {
        // A first load shows placeholders; a reload keeps the last figures,
        // greyed, until the new ones arrive.
        let hasData = !background.isLoading || !background.live.isEmpty || !background.stale.isEmpty
        let summary = HomeStatus.background(leftOver: background.stale.count, hasChecked: hasData,
                                            hasFaults: !background.faults.isEmpty)
        return StatCard(
            title: "Background", symbol: "gearshape.2",
            figure: "\(background.live.count) listed",
            status: summary.status, phrase: summary.phrase, isRefreshing: background.isLoading && hasData
        ) { shell.go(to: .background) }
    }

    private var developerCard: some View {
        let count = developer.caches.count
        let firstLoad = developer.isScanning && developer.caches.isEmpty
        return StatCard(
            title: "Developer", symbol: "hammer",
            figure: ByteText.short(developer.totalBytes),
            status: firstLoad ? .checking : .neutral,
            phrase: count == 1 ? "1 build cache" : "\(count) build caches",
            isRefreshing: developer.isScanning && !firstLoad
        ) { shell.go(to: .developer) }
    }

    private var updatesCard: some View {
        let count = updates.count
        return StatCard(
            title: "Updates", symbol: "arrow.down.circle",
            figure: count.map { "\($0) available" } ?? "…",
            status: count == nil ? .checking : (count == 0 ? .clear : .attention),
            phrase: updates.check.map { "Checked \($0.checked) apps" } ?? "Checking",
            isRefreshing: updates.isChecking && count != nil
        ) { shell.go(to: .apps, lens: .updates) }
    }

    // MARK: - Recently installed

    private func recentCard(_ recent: [InstalledApplication]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Recently installed")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Text("Last 5 days")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 104))], spacing: 14) {
                ForEach(recent) { app in
                    Button {
                        shell.go(to: .apps, lens: .all)
                        applications.select(app)
                    } label: {
                        VStack(spacing: 6) {
                            BrimIcon(source: .bundle(app.url), size: 44)
                            Text(app.name)
                                .font(.caption)
                                .foregroundStyle(Palette.inkSecondary)
                                .lineLimit(1)
                                .frame(width: 84)
                        }
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("\(app.name), recently installed")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A note that needs the person, above the cards: Full Disk Access, or
/// removals still in the Trash.
private struct HomeNote: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.brimRowTitle).foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(18)
        .card()
    }
}
