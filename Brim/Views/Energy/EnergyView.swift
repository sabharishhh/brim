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

    var body: some View {
        content
            .pageTitle("Energy")
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
                        conditionRow
                        if !model.appsKeepingMacAwake.isEmpty {
                            awake
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

    // MARK: - How the Mac is coping

    /// From interfaces Apple publishes. Deliberately not a temperature in
    /// degrees: there is no public API for one, and `thermalState` answers
    /// the question somebody has, which is whether the Mac is slowing down
    /// to cool itself.
    private var conditionRow: some View {
        HStack(alignment: .top, spacing: 16) {
            conditionCard(
                symbol: model.condition.thermal.symbolName,
                status: model.condition.thermal.isNoteworthy ? .attention : .clear,
                caption: "Temperature", title: model.condition.thermal.title,
                phrase: model.condition.thermal.isNoteworthy ? "Slowing down to cool" : "No slowdown"
            )
            if let power = model.condition.power {
                conditionCard(
                    symbol: power.symbolName, status: .neutral, caption: "Power", title: power.title,
                    phrase: model.condition.lowPowerMode ? "Low Power Mode on"
                        : (power.isOnBattery ? "On battery" : "On the adapter")
                )
            }
        }
    }

    private func conditionCard(
        symbol: String, status: CardStatus, caption: String, title: String, phrase: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(caption, systemImage: symbol)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            Text(title)
                .font(.brimFigure)
                .foregroundStyle(Palette.ink)
            if let phrase {
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(phrase)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            } else {
                StatusDot(status: status)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([caption, title, phrase].compactMap(\.self).joined(separator: ", "))
    }

    // MARK: - Keeping the Mac awake

    /// The one thing neither System Settings nor Activity Monitor names:
    /// which application is holding the Mac awake.
    private var awake: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Keeping this Mac awake", trailing: "Quitting one releases it")
            ForEach(model.appsKeepingMacAwake) { held in
                HStack(spacing: 12) {
                    BrimIcon(source: icon(bundlePath: held.bundlePath, name: held.owner), size: Metrics.compactRowIcon)
                    Text(held.owner)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Label(held.kind.title, systemImage: held.kind.symbolName)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(held.owner), \(held.kind.title)")
            }
        }
        .padding(8)
        .card()
    }

    // MARK: - Drawing power

    private var drawing: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(
                "Drawing power now",
                trailing: model.applications.count > 1 ? model.busiest.map { "\($0.name) most" } : nil
            )
            if model.applications.isEmpty {
                Label("Nothing open is drawing much", systemImage: "leaf")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(12)
            } else {
                ForEach(model.applications) { reading in
                    row(reading)
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
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func row(_ reading: EnergyModel.Reading) -> some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon(bundlePath: reading.bundlePath, name: reading.name))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(reading.name)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(rate(reading))
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                }
                HStack(spacing: 10) {
                    // Against the busiest app, so rows compare as a shape.
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(3, proxy.size.width * model.share(of: reading)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 5)
                    Text(reading.dominantCost(over: model.window).sentence)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: 180, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(reading.name)
        .accessibilityValue("\(rate(reading)), \(reading.dominantCost(over: model.window).sentence)")
    }

    private func icon(bundlePath: String?, name: String) -> IconSource {
        bundlePath.map { .bundle(URL(fileURLWithPath: $0)) } ?? .monogram(Monogram(name: name))
    }

    /// Watts once there is a watt to show. People have a feel for watts,
    /// and nobody has one for 1053 milliwatts.
    private func rate(_ reading: EnergyModel.Reading) -> String {
        let value = reading.milliwatts(over: model.window)
        if value < 0.5 {
            return "Under 1 mW"
        }
        if value < 1000 {
            return String(format: "%.0f mW", value)
        }
        return String(format: "%.1f W", value / 1000)
    }
}
