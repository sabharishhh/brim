import BrimCore
import BrimUI
import SwiftUI
import SystemConfiguration

/// The first page: this Mac at a glance, then in depth one click away.
///
/// A headline, what changed since Brim last looked, three tiles and a place
/// to drop an app. Nothing here is a number that was not measured: every
/// figure waits for its scan, and until then says it is looking.
struct HomeView: View {
    // Each model observed directly. Nested `ObservableObject`s do not
    // propagate, so observing `SectionModels` alone would never redraw.
    @ObservedObject private var leftovers: LeftoversModel
    @ObservedObject private var applications: ApplicationsModel
    @ObservedObject private var recovery: RecoveryStatusModel
    @ObservedObject private var fullDiskAccess: FullDiskAccessModel
    @ObservedObject private var background: BackgroundModel
    @ObservedObject private var storage: StorageModel
    private let models: SectionModels

    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(AppSession.self) private var session

    init(models: SectionModels) {
        self.models = models
        leftovers = models.leftovers
        applications = models.applications
        recovery = models.recovery
        fullDiskAccess = models.fullDiskAccess
        background = models.background
        storage = models.storage
    }

    var body: some View {
        ScrollView {
            // Centred with spacers, not `.frame(maxWidth: .infinity)`, which
            // reports the content as willing to take any width and once made
            // the window open at half the display.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !fullDiskAccess.isGranted {
                        accessNote
                    }
                    if !recovery.isEmpty {
                        recoveryNote
                    }
                    tiles
                    SinceLastLook(
                        history: applications.history, applications: applications.applications,
                        newLeftovers: newLeftoverOwners
                    ) { shell.go(to: .leftovers) }
                    if !recentlyInstalled.isEmpty {
                        recentRow
                    }
                    DropWell { models.openApplication(from: $0, shell: shell) }
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(Metrics.pagePadding)
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .task { await leftovers.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .task { await background.loadIfNeeded(service: service) }
        .task { await storage.loadIfNeeded(service: service) }
        .onAppear { fullDiskAccess.startObserving() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.macName)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.inkTertiary)
                Spacer()
                FreshnessLabel(freshness: freshness)
            }
            Text(HomeHeadline.sentence(headlineFacts))
                .font(.brimHeadline)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .brimAnimation(Motion.standard, value: HomeHeadline.sentence(headlineFacts))
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The computer's own name, as Sharing settings has it. Read once:
    /// `Host.current()` can wait on the network to answer the same thing.
    private static let macName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"

    private var headlineFacts: HomeHeadline.Facts {
        HomeHeadline.Facts(
            removedApps: leftovers.orphanedGroups.count,
            removedAppBytes: leftovers.orphanedGroups.reduce(0) { $0 + $1.totalBytes },
            unclaimed: leftovers.unclaimedEntries.count,
            unclaimedBytes: leftovers.unclaimedGroups.reduce(0) { $0 + $1.totalBytes },
            hasChecked: leftovers.checkedAt != nil,
            isChecking: leftovers.isScanning,
            canSeeLibrary: fullDiskAccess.isGranted,
            failed: leftovers.errorMessage != nil
        )
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

    /// Owners with something the Leftovers list did not show last time it
    /// was looked at (`VisitMemory`). Zero until it has been looked at once.
    private var newLeftoverOwners: Int {
        let new = session.visits.newItems(in: "leftovers", current: Set(leftovers.all.map(\.id)))
        guard !new.isEmpty else { return 0 }
        return (leftovers.orphanedGroups + leftovers.unclaimedGroups)
            .filter { $0.items.contains { new.contains($0.id) } }.count
    }

    // MARK: - Notes

    private var accessNote: some View {
        HomeNote(
            symbol: "lock", tint: Palette.caution,
            title: "Brim can see only part of this Mac",
            detail: "Without Full Disk Access most of what apps leave behind is out of sight, "
                + "so every number here is lower than the truth.",
            actionTitle: "Open Settings"
        ) { FullDiskAccess.openSettings() }
    }

    private var recoveryNote: some View {
        let count = recovery.items.count
        return HomeNote(
            symbol: "arrow.uturn.backward", tint: .accentColor,
            title: count == 1 ? "1 removal can still be put back" : "\(count) removals can still be put back",
            detail: ByteText.inSentence(recovery.totalBytes) + " is in the Trash until you empty it.",
            actionTitle: "Open Journal"
        ) { shell.go(to: .journal) }
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(alignment: .top, spacing: 16) {
            Tile(
                title: "Leftovers", figure: leftoverFigure, caption: leftoverCaption,
                icons: topOwners.map(\.ownerIcon), morphID: "page.leftovers"
            ) { shell.go(to: .leftovers) }
            Tile(
                title: "Background", figure: background.isLoading ? "…" : "\(background.live.count)",
                caption: backgroundCaption, morphID: "page.background"
            ) { shell.go(to: .background) }
            Tile(
                title: "Space", figure: spaceFigure, caption: spaceCaption, morphID: "page.space"
            ) { shell.go(to: .space) }
        }
    }

    private var topOwners: [LeftoverGroup] {
        let owners = leftovers.orphanedGroups.isEmpty ? leftovers.unclaimedGroups : leftovers.orphanedGroups
        return Array(owners.sorted { $0.totalBytes > $1.totalBytes }.prefix(3))
    }

    private var leftoverFigure: String {
        guard leftovers.checkedAt != nil else { return "…" }
        let groups = leftovers.orphanedGroups + leftovers.unclaimedGroups
        return ByteText.short(groups.reduce(0) { $0 + $1.totalBytes })
    }

    private var leftoverCaption: String {
        guard leftovers.checkedAt != nil else { return "Looking" }
        let removed = leftovers.orphanedGroups.count
        if removed > 0 {
            return removed == 1 ? "from 1 removed app" : "from \(removed) removed apps"
        }
        let unclaimed = leftovers.unclaimedEntries.count
        return unclaimed == 0 ? "nothing left behind" : "\(unclaimed) that no app claims"
    }

    private var backgroundCaption: String {
        guard !background.isLoading else { return "Looking" }
        let stale = background.stale.count
        return stale == 0 ? "running, nothing left over" : "running, \(stale) left over"
    }

    private var spaceFigure: String {
        guard let volume = storage.startupVolume else { return "…" }
        return ByteText.short(volume.freeRightNow) + " free"
    }

    private var spaceCaption: String {
        guard let volume = storage.startupVolume else { return storage.isLoading ? "Looking" : "Not read yet" }
        return "of \(ByteText.short(volume.capacity)) on \(volume.name)"
    }

    // MARK: - Recently installed

    private var recentlyInstalled: [InstalledApplication] {
        let grouper = AppGrouper()
        return applications.applications.filter(grouper.isRecentlyInstalled)
            .sorted { ($0.installedAt ?? .distantPast) > ($1.installedAt ?? .distantPast) }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently installed")
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(recentlyInstalled) { app in
                        Button {
                            shell.go(to: .apps, lens: .all)
                            applications.select(app)
                        } label: {
                            VStack(spacing: 6) {
                                BrimIcon(source: .bundle(app.url), size: 48)
                                Text(app.name)
                                    .font(.caption)
                                    .foregroundStyle(Palette.inkSecondary)
                                    .lineLimit(1)
                                    .frame(width: 72)
                            }
                        }
                        .buttonStyle(.press)
                        .accessibilityLabel("\(app.name), installed recently")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// A note that needs the person, above the tiles: Full Disk Access, or
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
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
        .padding(16)
        .card()
    }
}
