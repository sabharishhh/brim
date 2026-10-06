import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Where the space went, told as separate numbers.
///
/// Finder shows one figure for free space and it already includes room
/// macOS is only holding on to, which is why deleting something large can
/// leave it unchanged. That single number is how cleaning utilities end up
/// claiming gigabytes nobody ever sees. Here the parts stay apart and each
/// one says what it is (plan §8: volumes, then the three numbers, then the
/// largest apps).
struct SpaceView: View {
    @ObservedObject var model: StorageModel
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var developer: DeveloperModel
    @ObservedObject var history: RemovalHistoryModel
    @ObservedObject var appData: AppDataModel
    @SwiftUI.Environment(\.brimService) private var service
    /// The visit before this one, read when the page opens.
    @State private var previous: SpaceSnapshot?
    /// This visit, once everything on the page is measured.
    @State private var current: SpaceSnapshot?
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            // Centred with spacers, not a greedy frame, so the column keeps
            // its width without asking the window for more.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                    if let volume = model.startupVolume {
                        startup(volume)
                            .refreshing(model.isLoading)
                    } else if model.isLoading {
                        placeholder
                    }
                    SpaceSoftwareCard(
                        storage: model, applications: applications, developer: developer, history: history,
                        appData: appData
                    )
                    if let current {
                        SpaceChangesCard(previous: previous, current: current)
                    }
                    SpaceLargestApps(applications: applications, appData: appData)
                    let others = model.volumes.filter { $0.id != model.startupVolume?.id }
                    if !others.isEmpty {
                        otherVolumes(others)
                            .refreshing(model.isLoading)
                    }
                }
                .frame(maxWidth: Metrics.cardPageWidth, alignment: .leading)
                .padding(Metrics.pagePadding)
                Spacer(minLength: 0)
            }
        }
        .pageTitle("Space", centredWidth: Metrics.cardPageWidth)
        .task { await model.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await developer.loadIfNeeded(service: service) }
        .task {
            if history.records.isEmpty {
                await history.load(service: service)
            }
        }
        .task { previous = SpaceHistory.previous(to: Date(), in: SpaceHistory.load()) }
        // App data needs the app list, and the developer caches to leave out.
        .task(id: "\(applications.applications.count)|\(developer.isScanning)") {
            guard !applications.applications.isEmpty, !developer.isScanning,
                  !appData.hasMeasured, !appData.isMeasuring else { return }
            await appData.measure(
                service: service, applications: applications.applications, developer: developer.caches
            )
        }
        .onChange(of: isMeasured) { _, measured in
            if measured {
                recordVisit()
            }
        }
        .onAppear {
            if isMeasured {
                recordVisit()
            }
        }
    }

    // MARK: - This visit

    /// Everything on the page has a figure.
    private var isMeasured: Bool {
        model.startupVolume != nil && model.hasEstimate && !model.isLoading
            && appData.hasMeasured && !appData.isMeasuring && !developer.isScanning
            && !history.isLoading && !applications.isLoading
    }

    /// Records the figures this visit showed, for the next one to subtract.
    private func recordVisit() {
        guard let volume = model.startupVolume else { return }
        let rows = SpaceSoftwareCard.rows(
            storage: model, applications: applications, developer: developer, history: history, appData: appData
        )
        var named: [String: Int64] = [:]
        for row in rows {
            if let bytes = row.bytes {
                named[row.title] = bytes
            }
        }
        var apps: [String: Int64] = [:]
        for app in appData.apps where app.totalBytes > 0 {
            apps[app.name, default: 0] += app.totalBytes
        }
        let snapshot = SpaceSnapshot(
            date: Date(), used: volume.used, free: volume.freeRightNow, rows: named, apps: apps
        )
        SpaceHistory.record(snapshot)
        current = snapshot
    }

    // MARK: - Startup volume

    private func startup(_ volume: VolumeAccount) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume.name, systemImage: "internaldrive")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(ByteText.short(volume.capacity)) total")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            MeterBar(segments: segments(volume), showsLegend: false)
            // Three facts, never added into one.
            HStack(alignment: .top, spacing: 12) {
                figure("Used", volume.used, "Files and apps", Palette.snow)
                figure(
                    "Held by macOS", volume.reclaimableByTheSystem, "Released when needed",
                    Palette.frost
                )
                figure("Free", volume.freeRightNow, "Available now", Palette.inkTertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Finder shows \(ByteText.short(volume.freeAsFinderReportsIt)) free", systemImage: "info.circle")
                    .foregroundStyle(Palette.inkSecondary)
                if !volume.snapshots.isEmpty {
                    snapshots(volume)
                }
            }
            .font(.brimFacts)
        }
        .padding(20)
        .card()
        .hoverLift()
    }

    private func segments(_ volume: VolumeAccount) -> [MeterSegment] {
        [
            MeterSegment(label: "Used", value: volume.used, color: Palette.snow),
            MeterSegment(
                label: "Held by macOS", value: volume.reclaimableByTheSystem, color: Palette.frost
            ),
            MeterSegment(label: "Free", value: volume.freeRightNow, color: Palette.well)
        ]
    }

    private func figure(_ title: String, _ bytes: Int64, _ phrase: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Text(ByteText.short(bytes))
                .font(.brimFigure)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Text(phrase)
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(title), \(phrase)")
        .accessibilityValue(ByteText.short(bytes))
    }

    /// By count and whether macOS will discard them, never by size: there
    /// is no supported way to ask what a snapshot holds, and a figure
    /// invented here would be the dishonesty this page exists to avoid.
    private func snapshots(_ volume: VolumeAccount) -> some View {
        let count = volume.snapshots.count
        let pinning = volume.pinningSnapshots.count
        let label = count == 1 ? "1 local snapshot" : "\(count) local snapshots"
        return HStack(spacing: 6) {
            Label(label, systemImage: "clock.arrow.circlepath")
                .foregroundStyle(Palette.inkSecondary)
            if pinning > 0 {
                Text("·").foregroundStyle(Palette.inkTertiary)
                Text("\(pinning) holding deleted files. Deleting may free less.")
                    .foregroundStyle(Palette.caution)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBar(width: 160)
            SkeletonBar(width: 520, height: 8)
            HStack(spacing: 40) {
                SkeletonBar(width: 96, height: 24)
                SkeletonBar(width: 96, height: 24)
                SkeletonBar(width: 96, height: 24)
            }
        }
        .shimmer()
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityLabel("Checking")
    }

    // MARK: - Other volumes

    private func otherVolumes(_ volumes: [VolumeAccount]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other volumes")
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(volume.name, systemImage: volume.isRemovable ? "externaldrive" : "internaldrive")
                            .font(.brimRowTitle)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(ByteText.short(volume.freeRightNow)) free of \(ByteText.short(volume.capacity))")
                            .font(.brimFacts)
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    MeterBar(segments: segments(volume), showsLegend: false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(volume.name), \(ByteText.short(volume.freeRightNow)) free of \(ByteText.short(volume.capacity))"
                )
            }
        }
        .padding(20)
        .card()
        .hoverLift()
    }
}
