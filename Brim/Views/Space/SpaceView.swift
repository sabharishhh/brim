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
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            // Centred with spacers, not a greedy frame, so the column keeps
            // its width without asking the window for more.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let volume = model.startupVolume {
                        startup(volume)
                            .refreshing(model.isLoading)
                    } else if model.isLoading {
                        placeholder
                    }
                    HStack(alignment: .top, spacing: 16) {
                        leftoversCard
                        developerCard
                    }
                    if !largest.isEmpty {
                        largestApps
                    }
                    let others = model.volumes.filter { $0.id != model.startupVolume?.id }
                    if !others.isEmpty {
                        otherVolumes(others)
                            .refreshing(model.isLoading)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(Metrics.pagePadding)
                Spacer(minLength: 0)
            }
        }
        .task { await model.loadIfNeeded(service: service) }
        .task { await applications.loadIfNeeded(service: service) }
        .task { await developer.loadIfNeeded(service: service) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Space")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }
            Spacer()
        }
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
                figure("Used", volume.used, "Files and apps", Palette.hue(1))
                figure(
                    "Held by macOS", volume.reclaimableByTheSystem, "Released when needed",
                    Palette.hue(1).opacity(0.4)
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
    }

    private func segments(_ volume: VolumeAccount) -> [MeterSegment] {
        [
            MeterSegment(label: "Used", value: volume.used, color: Palette.hue(1)),
            MeterSegment(
                label: "Held by macOS", value: volume.reclaimableByTheSystem, color: Palette.hue(1).opacity(0.4)
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
                Text("\(pinning) kept until removed, so deleting may free nothing")
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

    // MARK: - What can be cleared

    private var leftoversCard: some View {
        let status: CardStatus = !model.hasEstimate
            ? .checking : (model.estimateUnavailable ? .partial : (model.brimCanClear > 0 ? .attention : .clear))
        let phrase = if !model.hasEstimate {
            "Checking"
        } else if model.estimateUnavailable {
            "Could not read"
        } else if model.brimCanClearCount == 0 {
            "Nothing found"
        } else {
            model.brimCanClearCount == 1 ? "From 1 removed app" : "From \(model.brimCanClearCount) removed apps"
        }
        return StatCard(
            title: "Remnants", symbol: "app.dashed",
            figure: model.brimCanClearFigure, status: status, phrase: phrase,
            isRefreshing: model.isLoading && model.hasEstimate
        ) { shell.go(to: .leftovers) }
    }

    private var developerCard: some View {
        let checked = !developer.caches.isEmpty || !developer.isScanning
        return StatCard(
            title: "Developer", symbol: "hammer",
            figure: ByteText.short(developer.totalBytes),
            status: checked ? .neutral : .checking,
            phrase: developer.caches.count == 1 ? "1 build cache" : "\(developer.caches.count) build caches",
            isRefreshing: developer.isScanning && !developer.caches.isEmpty
        ) { shell.go(to: .developer) }
    }

    // MARK: - Largest apps

    private var largest: [InstalledApplication] {
        Array(applications.applications.filter { !$0.isSystemProtected }
            .sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
            .prefix(5))
    }

    private var largestApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Largest apps")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button("Show All") { shell.go(to: .apps, lens: .all) }
                    .buttonStyle(.borderless)
                    .font(.brimFacts)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            ForEach(largest) { app in
                Button {
                    shell.go(to: .apps, lens: .all)
                    _ = applications.selectApplication(at: app.url)
                } label: {
                    HStack(spacing: 12) {
                        BrimIcon(source: .bundle(app.url), size: Metrics.compactRowIcon)
                        Text(app.name)
                            .font(.brimRowTitle)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(ByteText.short(app.bundleSizeBytes))
                            .font(.brimFacts)
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .rowHighlight(isInspected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(app.name), \(ByteText.short(app.bundleSizeBytes))")
            }
        }
        .padding(8)
        .card()
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
    }
}
