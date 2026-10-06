import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// What your applications are drawing, and how the Mac is coping.
///
/// Applications, and nothing else. An earlier version listed the services
/// underneath them too: `powerd` appeared under "Keeping this Mac awake"
/// holding "Prevent sleep while display is on", which is macOS working
/// correctly and read as an internal process stopping the Mac from ever
/// sleeping. The line is not who wrote it, it is whether there is a window
/// to quit.
///
/// Nothing runs between readings. No agent, no timer, no background job: a
/// reading happens when Take a Reading in the toolbar is pressed and describes the seconds it
/// covered.
struct EnergyView: View {
    @ObservedObject var model: EnergyModel
    @SwiftUI.Environment(\.brimService) private var service
    /// The row the pointer is over, which shows its Quit button.
    @State private var hovered: String?

    var body: some View {
        content
            .pageTitle("Energy", centredWidth: Metrics.cardPageWidth)
            .task { await model.loadIfNeeded(service: service) }
    }

    @ViewBuilder
    private var content: some View {
        if model.isSampling, model.applications.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                        EnergyStatusCard(battery: model.battery, condition: model.condition)
                        if let history = model.history {
                            if !history.charge.isEmpty || !history.sleeps.isEmpty {
                                EnergyHistoryCard(history: history, battery: model.battery)
                            }
                            if !model.awakeRequests.isEmpty || !model.appsKeepingMacAwake.isEmpty {
                                EnergyAwakeCard(
                                    requests: model.awakeRequests, holding: model.appsKeepingMacAwake,
                                    since: history.since
                                )
                            }
                        } else if model.isReadingHistory {
                            historyPlaceholder
                        }
                        drawing
                    }
                    .frame(maxWidth: Metrics.cardPageWidth, alignment: .leading)
                    .padding(Metrics.pagePadding)
                    Spacer(minLength: 0)
                }
            }
            .refreshing(model.isSampling)
        }
    }

    // MARK: - The last few days

    /// Reading power management's log takes a few seconds, so its two
    /// cards hold their place while it does.
    private var historyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBar(width: 120)
            SkeletonBar(width: 520, height: 110)
        }
        .shimmer()
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityLabel("Reading the last few days")
    }

    // MARK: - Drawing power

    private var drawing: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(
                "Using power now",
                trailing: model.applications.isEmpty ? nil
                    : "\(rate(milliwatts: model.milliwatts(of: model.applications))) in all"
            )
            if model.applications.isEmpty {
                Label("Nothing open is drawing much", systemImage: "leaf")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(12)
            } else {
                ForEach(model.shownApplications) { reading in
                    row(reading)
                }
                if let others = model.others {
                    othersRow(others)
                }
            }
            if let note = model.condition.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .padding(8)
        .card()
        .hoverLift()
    }

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func row(_ reading: EnergyModel.Reading) -> some View {
        let quittable = reading.bundlePath != nil
        return HStack(spacing: 12) {
            BrimIcon(source: icon(bundlePath: reading.bundlePath, name: reading.name))
            rowFacts(reading, showsQuit: quittable && hovered == reading.id)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .contentShape(.rect)
        .onHover { inside in
            if inside {
                hovered = reading.id
            } else if hovered == reading.id {
                hovered = nil
            }
        }
        .contextMenu {
            if quittable {
                Button("Quit \(reading.name)") { quit(reading) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(reading.name)
        .accessibilityValue(
            "\(rate(milliwatts: reading.milliwatts(over: model.window))), "
                + "\(Int((model.share(of: reading) * 100).rounded())) percent of the total, "
                + reading.dominantCost(over: model.window).sentence
        )
        .accessibilityActions {
            if quittable {
                Button("Quit \(reading.name)") { quit(reading) }
            }
        }
    }

    private func rowFacts(_ reading: EnergyModel.Reading, showsQuit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(reading.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                if showsQuit {
                    Button("Quit") { quit(reading) }
                        .capsuleAction()
                        .controlSize(.small)
                        .help("Quit \(reading.name)")
                }
                Text(rate(milliwatts: reading.milliwatts(over: model.window)))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
            }
            HStack(spacing: 10) {
                shareBar(model.share(of: reading), color: Palette.snow)
                Text(reading.dominantCost(over: model.window).sentence)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 180, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }

    /// The rest, as one row, so a long tail of small numbers does not
    /// push the apps that matter out of the card.
    private func othersRow(_ others: (count: Int, nanojoules: UInt64)) -> some View {
        let label = others.count == 1 ? "1 other app" : "\(others.count) other apps"
        let watts = rate(milliwatts: model.milliwatts(nanojoules: others.nanojoules))
        return HStack(spacing: 12) {
            Color.clear.frame(width: Metrics.rowIcon, height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Text(watts)
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
                HStack(spacing: 10) {
                    shareBar(model.share(of: others.nanojoules), color: Palette.mist)
                    Color.clear.frame(width: 180, height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(label)
        .accessibilityValue(watts)
    }

    private func shareBar(_ share: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * share))
            }
        }
        .frame(height: 5)
    }

    /// Asks the app to quit, the way the Dock does. Never a force quit: an
    /// app with unsaved work gets to ask about it. A fresh reading follows,
    /// so the row goes once the app has.
    private func quit(_ reading: EnergyModel.Reading) {
        guard let path = reading.bundlePath else { return }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        // Never Brim itself, which is told apart by where it lives.
        guard target != Bundle.main.bundleURL.standardizedFileURL else { return }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == target
        }
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await model.sample(service: service)
        }
    }

    private func icon(bundlePath: String?, name: String) -> IconSource {
        bundlePath.map { .bundle(URL(fileURLWithPath: $0)) } ?? .monogram(Monogram(name: name))
    }

    /// Watts once there is a watt to show. People have a feel for watts,
    /// and nobody has one for 1053 milliwatts.
    private func rate(milliwatts value: Double) -> String {
        if value < 0.5 {
            return "Under 1 mW"
        }
        if value < 1000 {
            return String(format: "%.0f mW", value)
        }
        return String(format: "%.1f W", value / 1000)
    }
}
