import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// The landing surface: what is worth your attention on this Mac, by area.
///
/// Deliberately not a list. Review used to render `service.leftovers()` in a
/// table — the same call, the same rows and the same two categories as the
/// Leftovers section, which made two sidebar entries that did the same job.
/// Ranking findings across every source is only meaningful once there are
/// several sources; until then an aggregator over one input is a copy of it.
///
/// So this summarises instead, and is honest about what has not been looked
/// at. An area that could not be read says so rather than showing zero,
/// which is the same distinction `RegistrationCoverage` draws and for the
/// same reason: "nothing found" and "did not look" are different claims.
struct ReviewSummaryView: View {
    @Binding var navigationSelection: NavigationItem?

    // Each model is observed directly rather than through the container.
    // `@ObservedObject var models: SectionModels` subscribes to
    // SectionModels' own publisher, which never fires — the nested models'
    // `@Published` changes do not propagate through a parent object. The
    // scans ran and the view simply never redrew, showing zero for
    // everything.
    @ObservedObject private var leftovers: LeftoversModel
    @ObservedObject private var applications: ApplicationsModel
    @ObservedObject private var recovery: RecoveryStatusModel
    @ObservedObject private var fullDiskAccess: FullDiskAccessModel
    @ObservedObject private var background: BackgroundModel
    @ObservedObject private var storage: StorageModel
    @ObservedObject private var developer: DeveloperModel
    @ObservedObject private var updates: UpdatesModel

    init(navigationSelection: Binding<NavigationItem?>, models: SectionModels) {
        self._navigationSelection = navigationSelection
        self.leftovers = models.leftovers
        self.applications = models.applications
        self.recovery = models.recovery
        self.fullDiskAccess = models.fullDiskAccess
        self.background = models.background
        self.storage = models.storage
        self.developer = models.developer
        self.updates = models.updates
    }

    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        ScrollView {
            // Centred with spacers rather than `.frame(maxWidth: .infinity)`.
            // That modifier reports the content as willing to take any
            // width, which SwiftUI resolves against the display: the window
            // opened at half the screen and ignored `.defaultSize` entirely.
            // A `Spacer(minLength: 0)` centres without asking for width.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !fullDiskAccess.isGranted { fullDiskAccessBanner }
                    if !recovery.isEmpty { recoveryBanner }
                    areas
                }
                // Capped because a line of prose past ~900pt is hard to read.
                .frame(maxWidth: 940, alignment: .leading)
                .padding(24)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("This Mac").font(.largeTitle).fontWeight(.bold)
                Text(leftovers.isScanning
                     ? "Looking…"
                     : "Everything software has left on this Mac.")
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Not drawn until there is a measurement behind it. While the
            // sweep was running `leftovers.all` is empty, so this rendered a
            // large, confident "Empty" over the word "unattributed" as the
            // first thing anybody saw on opening Brim, seconds before the
            // real figure replaced it. A zero nobody has measured is the one
            // number this product must never print.
            if !leftovers.isScanning {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteText.short(unclaimedBytes))
                        .font(.title).fontWeight(.semibold).monospacedDigit()
                    Text("unattributed").font(.caption).foregroundColor(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(ByteText.short(unclaimedBytes)) unattributed")
            }
        }
    }

    private var unclaimedBytes: Int64 {
        leftovers.all.reduce(0) { $0 + $1.size }
    }

    // MARK: - Banners

    private var fullDiskAccessBanner: some View {
        banner(
            symbol: "lock",
            tint: .orange,
            title: "Full Disk Access required",
            detail: "Without it most of what an application leaves behind is invisible, so the numbers "
                  + "below are undercounts.",
            action: ("Open Settings", { FullDiskAccess.openSettings() })
        )
    }

    private var recoveryBanner: some View {
        banner(
            symbol: "arrow.uturn.backward",
            tint: .accentColor,
            title: "\(recovery.items.count) "
                 + "\(recovery.items.count == 1 ? "removal is" : "removals are") still recoverable",
            detail: ByteText.inSentence(recovery.totalBytes)
                  + " is sitting in the Trash. You can put it back until you empty it.",
            action: ("Review in History", { navigationSelection = .history })
        )
    }

    private func banner(
        symbol: String, tint: Color, title: String, detail: String,
        action: (String, () -> Void)
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action.0) { action.1() }
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Areas

    private var areas: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Areas").font(.headline)
            ForEach(rankedAreas, id: \.item) { entry in
                entry.view
            }
        }
    }

    /// Every area, ordered by how much there is to act on here.
    ///
    /// Nothing about the ranking is shown: no score, no percentage, no
    /// colour. The order is the whole of it, so the first card is the one
    /// worth reading first on this Mac rather than whichever happened to
    /// be declared first.
    private var rankedAreas: [(item: NavigationItem, view: AnyView)] {
        let built: [(NavigationItem, ReviewRanking.Finding, AnyView)] = [
            (
                .leftovers,
                // Counted in groups, which is what the Leftovers screen
                // shows. This card counted raw locations, so the summary
                // promised "18 orphaned, 235 unclaimed" and the screen one
                // click away showed 7 and 217. Both numbers were right about
                // different things and the person could only see that one of
                // them was wrong.
                ReviewRanking.Finding(
                    area: "leftovers", bytes: unclaimedBytes,
                    count: leftovers.orphanedGroups.count,
                    confidence: leftovers.orphanedGroups.isEmpty ? .possible : .named,
                    isWorking: leftovers.isScanning
                ),
                AnyView(card(
                    .leftovers, "tray.full", "Leftovers",
                    leftovers.isScanning
                        ? .working
                        : .counted(
                            "\(leftovers.orphanedGroups.count) orphaned · "
                            + "\(leftovers.unclaimedGroups.count) unclaimed",
                            unclaimedBytes
                          ),
                    "Folders and files left behind by software that is no longer here."
                ))
            ),
            (
                .developer,
                ReviewRanking.Finding(
                    area: "developer", bytes: developer.totalBytes,
                    count: developer.caches.count, confidence: .certain,
                    isWorking: developer.isScanning
                ),
                AnyView(card(
                    .developer, "hammer", "Developer",
                    developer.isScanning
                        ? .working
                        : .counted("\(developer.caches.count) build caches", developer.totalBytes),
                    "Space your build tools are holding, and what clearing each one costs."
                ))
            ),
            (
                .background,
                ReviewRanking.Finding(
                    area: "background", count: background.stale.count,
                    confidence: background.stale.isEmpty ? .informational : .named,
                    isWorking: background.isLoading
                ),
                AnyView(card(
                    .background, "gearshape.2", "Background",
                    background.isLoading
                        ? .working
                        : .counted(background.stale.isEmpty
                            ? "\(background.live.count) running, nothing left over"
                            : "\(background.stale.count) left over, "
                              + "\(background.live.count) running",
                            nil),
                    "What macOS has been told to run at login and in the background."
                ))
            ),
            (
                .updates,
                ReviewRanking.Finding(
                    area: "updates",
                    count: updates.stranded.count + updates.report.orphanedAgents.count,
                    confidence: .likely, isWorking: updates.isLoading
                ),
                AnyView(card(
                    .updates, "arrow.triangle.2.circlepath", "Updates",
                    updates.isLoading ? .working : .counted(updates.report.summary, nil),
                    "Which applications update themselves, and which you update by hand."
                ))
            ),
            (
                .applications,
                ReviewRanking.Finding(
                    area: "applications", count: applications.applications.count,
                    confidence: .informational, isWorking: applications.isLoading
                ),
                AnyView(card(
                    .applications, "square.grid.2x2", "Applications",
                    applications.isLoading
                        ? .working
                        : .counted("\(applications.applications.count) installed", nil),
                    "Every application installed, and everything each one has put on this Mac."
                ))
            ),
            (
                .storage,
                ReviewRanking.Finding(
                    area: "storage", confidence: .informational, isWorking: storage.isLoading
                ),
                AnyView(card(
                    .storage, "internaldrive", "Storage",
                    storage.isLoading
                        ? .working
                        : storage.startupVolume.map {
                            .counted(ByteText.short($0.freeRightNow) + " free right now", nil)
                          } ?? .notChecked("Full Disk Access is needed to read the volumes."),
                    "Free space, and what is being held back from it."
                ))
            ),
            (
                .energy,
                ReviewRanking.Finding(area: "energy", confidence: .informational),
                AnyView(card(
                    .energy, "bolt", "Energy",
                    .note("Open it to take a reading."),
                    "Which applications have been using the battery."
                ))
            ),
        ]

        let ranked = ReviewRanking.rank(built.map(\.1))
        return ranked.compactMap { finding in
            guard let match = built.first(where: { $0.1.area == finding.area }) else { return nil }
            return (item: match.0, view: match.2)
        }
    }

    private enum Status {
        case working
        case counted(String, Int64?)
        /// Something is genuinely in the way and the person can clear it.
        case notChecked(String)
        /// How this section works, which is not a problem and must not be
        /// drawn as one. Energy takes its reading when you open it, and
        /// saying so in orange behind a question mark made an ordinary
        /// design decision look like a fault on the opening screen.
        case note(String)
        case notBuilt
    }

    private func card(
        _ destination: NavigationItem, _ symbol: String, _ title: String,
        _ status: Status, _ detail: String
    ) -> some View {
        Button {
            navigationSelection = destination
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundColor(isAvailable(status) ? .accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(detail)
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    statusLine(status)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }

    /// Whether the icon is drawn in the accent colour, which is to say
    /// whether the section is ready to be used. A section explaining how it
    /// works is ready; one that is blocked is not.
    private func isAvailable(_ status: Status) -> Bool {
        switch status {
        case .counted, .working, .note: return true
        case .notChecked, .notBuilt: return false
        }
    }

    @ViewBuilder
    private func statusLine(_ status: Status) -> some View {
        switch status {
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Looking…").font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 1)
        case .counted(let summary, let bytes):
            HStack(spacing: 5) {
                Text(summary).fontWeight(.medium)
                if let bytes {
                    Text("·").foregroundColor(.secondary)
                    Text(ByteText.short(bytes))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .padding(.top, 1)
        case .notChecked(let why):
            // Not the same as zero, and saying zero here would be a lie.
            Label(why, systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        case .note(let text):
            Text(text)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        case .notBuilt:
            Text("Still to come")
                .font(.caption).foregroundColor(.secondary)
                .padding(.top, 1)
        }
    }
}
