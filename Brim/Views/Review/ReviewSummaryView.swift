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

    init(navigationSelection: Binding<NavigationItem?>, models: SectionModels) {
        self._navigationSelection = navigationSelection
        self.leftovers = models.leftovers
        self.applications = models.applications
        self.recovery = models.recovery
        self.fullDiskAccess = models.fullDiskAccess
    }

    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !fullDiskAccess.isGranted { fullDiskAccessBanner }
                if !recovery.isEmpty { recoveryBanner }
                areas
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await leftovers.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .onAppear { fullDiskAccess.startObserving() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("This Mac").font(.largeTitle).fontWeight(.bold)
                Text(leftovers.isScanning
                     ? "Looking…"
                     : "What software has left behind, and what Brim can still not see.")
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteCountFormatter.string(fromByteCount: unclaimedBytes, countStyle: .file))
                    .font(.title).fontWeight(.semibold).monospacedDigit()
                Text("unattributed").font(.caption).foregroundColor(.secondary)
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
            detail: "Brim cannot see most of an app's footprint without it, so everything below "
                  + "is incomplete.",
            action: ("Open Settings", { FullDiskAccess.openSettings() })
        )
    }

    private var recoveryBanner: some View {
        banner(
            symbol: "arrow.uturn.backward",
            tint: .accentColor,
            title: "\(recovery.items.count) "
                 + "\(recovery.items.count == 1 ? "removal is" : "removals are") still recoverable",
            detail: ByteCountFormatter.string(fromByteCount: recovery.totalBytes, countStyle: .file)
                  + " is in the Trash and can be put back until you empty it.",
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

            card(
                .leftovers, "tray.full",
                "Leftovers",
                leftovers.isScanning
                    ? .working
                    : .counted(
                        "\(leftovers.orphaned.count) orphaned · \(leftovers.unclaimed.count) unclaimed",
                        unclaimedBytes
                      ),
                "Files no installed application claims. Orphans name the record that "
                + "orphaned them; unclaimed items are shown but never pre-selected."
            )

            card(
                .applications, "square.grid.2x2",
                "Applications",
                applications.isLoading
                    ? .working
                    : .counted("\(applications.applications.count) installed", nil),
                "Pick an app to see everything it has put on this Mac, then remove it "
                + "and have Brim prove it is gone."
            )

            card(
                .background, "gearshape.2",
                "Background items",
                .notChecked("macOS requires administrator access to list these, and Brim "
                            + "does not ask for that during a scan."),
                "Login items and background services — including ones left registered by "
                + "software that is no longer installed."
            )

            ForEach(pending, id: \.0) { item, symbol, title, detail in
                card(item, symbol, title, .notBuilt, detail)
            }
        }
    }

    private var pending: [(NavigationItem, String, String, String)] {
        [
            (.storage, "internaldrive", "Storage",
             "Logical size, what is actually reclaimable, and what local snapshots are pinning."),
            (.energy, "bolt", "Energy",
             "What has been costing power, sampled rather than guessed."),
            (.developer, "hammer", "Developer",
             "Caches, simulators and derived data that build tools accumulate."),
            (.updates, "arrow.triangle.2.circlepath", "Updates",
             "Updater agents and helpers left running by software you have removed.")
        ]
    }

    private enum Status {
        case working
        case counted(String, Int64?)
        case notChecked(String)
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

    private func isAvailable(_ status: Status) -> Bool {
        if case .counted = status { return true }
        if case .working = status { return true }
        return false
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
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
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
        case .notBuilt:
            Text("Not built yet")
                .font(.caption).foregroundColor(.secondary)
                .padding(.top, 1)
        }
    }
}
