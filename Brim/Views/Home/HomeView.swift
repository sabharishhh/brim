import BrimCore
import BrimUI
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces
/// The first page: this Mac at a glance, then in depth one click away.
///
/// A grid of four columns. Space and Energy share the top row at two
/// columns each, the four counts follow one column each, then installing
/// and the Journal at two each, then recently installed apps across. A
/// narrow window has two columns, so nothing is squeezed and no card grows
/// tall. Short phrases only, and no number that was not measured: every
/// figure waits for its scan.
struct HomeView: View {
    // Each model observed directly. Nested `ObservableObject`s do not
    // propagate, so observing `SectionModels` alone would never redraw.
    @ObservedObject private var leftovers: LeftoversModel
    @ObservedObject private var applications: ApplicationsModel
    @ObservedObject private var recovery: RecoveryStatusModel
    @ObservedObject private var fullDiskAccess: FullDiskAccessModel
    @AppStorage(FullDiskAccess.requestedKey) private var accessRequestedAt = 0.0
    @ObservedObject private var background: BackgroundModel
    @ObservedObject private var storage: StorageModel
    @ObservedObject private var developer: DeveloperModel
    @ObservedObject private var updates: UpdatesModel
    @ObservedObject private var energy: EnergyModel
    @ObservedObject private var history: RemovalHistoryModel
    private let models: SectionModels
    /// The last two times Space measured, for what grew between them.
    @State private var spaceLooks: [SpaceSnapshot] = []

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
        energy = models.energy
        history = models.history
    }

    /// Below this the grid has two columns rather than four.
    @State private var isNarrow = false
    private static let spacing: CGFloat = 20

    var body: some View {
        ScrollView {
            // Centred with spacers, not `.frame(maxWidth: .infinity)`, which
            // reports the content as willing to take any width and once made
            // the window open at half the display.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: Self.spacing) {
                    if case .failed = freshness {
                        FreshnessLabel(freshness: freshness)
                    } else if case .partial = freshness {
                        FreshnessLabel(freshness: freshness)
                    }
                    if !fullDiskAccess.isGranted {
                        accessNote
                    }
                    if recovery.isAvailable, !recovery.isEmpty {
                        recoveryNote
                    }
                    grid
                        .onGeometryChange(for: Bool.self, of: { $0.size.width < 720 }, action: { isNarrow = $0 })
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let recent = applications.recentlyInstalled(now: context.date)
                        if !recent.isEmpty {
                            recentCard(recent)
                        }
                    }
                }
                .frame(maxWidth: Self.pageWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                Spacer(minLength: 0)
            }
        }
        .pageTitle("Home", centredWidth: Self.pageWidth)
        .task { await leftovers.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .task { await background.loadIfNeeded(service: service) }
        .task { await storage.loadIfNeeded(service: service) }
        .task { await developer.loadIfNeeded(service: service) }
        .task { await updates.loadIfNeeded(service: service) }
        .task { await energy.loadOverview() }
        .task {
            await history.load(service: service)
            await applications.loadIfNeeded(service: service)
            await history.recheck(installed: Set(applications.applications.compactMap(\.identity.bundleID)))
        }
        .task { spaceLooks = SpaceHistory.load() }
        .onAppear { fullDiskAccess.startObserving() }
    }

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

    /// Wider than a reading page: Home is a dashboard of cards.
    private static let pageWidth: CGFloat = 1000

    // MARK: - Notes

    private var accessNote: some View {
        let offer = AccessOffer.current(requestedAt: accessRequestedAt)
        return HomeNote(
            symbol: "lock", tint: Palette.caution,
            title: "Full Disk Access is off",
            detail: FullDiskAccess.isRecent(accessRequestedAt)
                ? "Switched Brim on? Reopen Brim to use it."
                : "Brim cannot see most of Library. Counts are low.",
            actionTitle: offer.title,
            action: offer.action
        )
    }

    private var recoveryNote: some View {
        let count = recovery.items.count
        return HomeNote(
            symbol: "arrow.uturn.backward", tint: Palette.ink,
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
            isRefreshing: storage.isLoading && volume != nil, fillsRow: true
        ) {
            if let volume {
                VStack(alignment: .leading, spacing: 10) {
                    // Three facts, never added into one: what is used, what
                    // macOS will release when it needs to, and what is free.
                    MeterBar(segments: [
                        MeterSegment(label: "Used", value: volume.used, color: Palette.snow),
                        MeterSegment(
                            label: "Held by macOS", value: volume.reclaimableByTheSystem,
                            color: Palette.frost
                        ),
                        MeterSegment(label: "Free", value: volume.freeRightNow, color: Palette.well)
                    ])
                    ForEach(spaceNotes, id: \.self) { note in
                        Text(note)
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
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
            isRefreshing: leftovers.isScanning && checked, fillsRow: true
        ) {
            if checked, size.isComplete, rebuilds + data > 0 {
                MeterBar(segments: [
                    MeterSegment(label: "Data", value: data, color: Palette.snow),
                    MeterSegment(label: "Rebuilds", value: rebuilds, color: Palette.frost)
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
            status: summary.status, phrase: summary.phrase, isRefreshing: background.isLoading && hasData,
            fillsRow: true
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
            isRefreshing: developer.isScanning && !firstLoad, fillsRow: true
        ) { shell.go(to: .developer) }
    }

    private var updatesCard: some View {
        let count = updates.count
        return StatCard(
            title: "Updates", symbol: "arrow.down.circle",
            figure: count.map { "\($0) available" } ?? "…",
            status: count == nil ? .checking : (count == 0 ? .clear : .attention),
            phrase: updates.check.map { "Checked \($0.checked) apps" } ?? "Checking",
            isRefreshing: updates.isChecking && count != nil, fillsRow: true
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
        .hoverLift()
    }
}

// MARK: - Layout

extension HomeView {
    /// Rows of equally wide cards, each row as tall as its tallest card.
    /// A `Grid` divided its columns by what each card asked for, so the
    /// counts were squeezed until "Updates" broke across two lines.
    private var grid: some View {
        VStack(spacing: Self.spacing) {
            if isNarrow {
                row { spaceCard }
                row { energyCard }
                row {
                    leftoversCard
                    backgroundCard
                }
                row {
                    developerCard
                    updatesCard
                }
                row { InstallCard() }
                row { journalCard }
            } else {
                row {
                    spaceCard
                    energyCard
                }
                row {
                    leftoversCard
                    backgroundCard
                    developerCard
                    updatesCard
                }
                row {
                    InstallCard()
                    journalCard
                }
            }
        }
    }

    /// Cards share the row's width equally; measured at their tallest, then
    /// each is offered that height.
    private func row(@ViewBuilder _ cards: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            cards()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var energyCard: some View {
        HomeEnergyCard(energy: energy) { shell.go(to: .energy) }
    }

    private var journalCard: some View {
        HomeJournalCard(history: history) { shell.go(to: .journal) }
    }

    /// From what Space measured on its last two visits, dated, because
    /// Home does not measure them itself.
    private var spaceNotes: [String] {
        guard let latest = spaceLooks.last else { return [] }
        var notes: [String] = []
        if let previous = SpaceHistory.previous(to: latest.date, in: spaceLooks),
           let change = SpaceHistory.changes(from: previous, to: latest, limit: 1).first {
            let sign = change.bytes > 0 ? "+" : "−"
            notes.append("\(change.title) \(sign)\(ByteText.short(abs(change.bytes))) between "
                + "\(Self.day.format(previous.date)) and \(Self.day.format(latest.date))")
        }
        if let largest = latest.apps.max(by: { $0.value < $1.value }) {
            notes.append("Largest app \(largest.key), \(ByteText.short(largest.value)) on "
                + Self.day.format(latest.date))
        }
        return notes
    }

    private static let day = Date.FormatStyle.dateTime.day().month(.abbreviated)
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
                // Decoration: the arrow was read out as "Undo".
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.brimRowTitle).foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .capsuleAction()
                .buttonBorderShape(.capsule)
        }
        .padding(18)
        .card()
        .hoverLift()
    }
}
