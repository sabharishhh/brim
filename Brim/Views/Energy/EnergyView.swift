import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What your applications are drawing, and how the Mac is coping.
///
/// Applications, and nothing else. An earlier version listed the services
/// underneath them too, which was accurate and was a mistake. `powerd`
/// appeared under "Keeping this Mac awake", holding an assertion named
/// "Prevent sleep while display is on". That is macOS working correctly, the
/// display being on because somebody is using the Mac, and it releases when
/// they stop. To anybody who did not already know that, it read as an
/// internal process stopping their Mac from ever sleeping.
///
/// The same applies to the rest. `coreaudiod` is busy because Music is
/// playing. `WindowServer` is busy because there are pixels on screen.
/// Listing them beside the app that caused them hands a person four suspects
/// for one event, three of which they cannot act on.
///
/// An application Apple ships is still an application. Music, Safari and
/// Mail are things somebody opened and can close, so they belong here. The
/// line is not who wrote it, it is whether there is a window to quit.
///
/// Nothing runs between readings. No agent, no timer, no background job: a
/// utility whose subject is software running when nobody asked it to cannot
/// leave something running when nobody asked it to. A reading happens when
/// the button is pressed and describes the seconds it covered.
struct EnergyView: View {
    @ObservedObject var model: EnergyModel
    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.loadIfNeeded(service: service) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Energy").font(.title2).fontWeight(.bold)
                Text("What your applications are drawing, and how the Mac is coping.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(model.isSampling ? "Reading…" : "Take a reading") {
                Task { await model.sample(service: service) }
            }
            .disabled(model.isSampling)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if model.isSampling && model.applications.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Watching what the Mac does for a couple of seconds.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 14) {
                        conditionRow
                        if !model.appsKeepingMacAwake.isEmpty { awakeCard }
                        applicationsCard
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(20)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - How the Mac is coping

    /// Two square cards, from interfaces Apple publishes.
    ///
    /// Deliberately not a temperature in degrees. There is no public API for
    /// one: every tool that shows a number reads it through
    /// `IOHIDEventSystemClient` or raw SMC keys, both private and both
    /// undocumented, and Apple has never shown a temperature anywhere in
    /// macOS including Activity Monitor. `ProcessInfo.thermalState` is what
    /// Apple publishes, and it answers the question somebody actually has,
    /// which is not "how many degrees" but "is my Mac being slowed down to
    /// cool itself".
    private var conditionRow: some View {
        HStack(spacing: 14) {
            squareCard(
                symbol: model.condition.thermal.symbolName,
                tint: model.condition.thermal.isNoteworthy ? .orange : .green,
                caption: "Temperature",
                title: model.condition.thermal.title,
                detail: model.condition.thermal.meaning
            )

            if let power = model.condition.power {
                squareCard(
                    symbol: power.symbolName,
                    tint: power.isOnBattery ? .accentColor : .green,
                    caption: "Power",
                    title: power.title,
                    detail: model.condition.lowPowerMode
                        ? "Low Power Mode is on, so the Mac is running slower to last longer."
                        : (power.isOnBattery
                           ? "Running on the battery, so what is drawing power costs you."
                           : "On the adapter, so nothing here is costing you battery.")
                )
            }
        }
    }

    private func squareCard(
        symbol: String, tint: Color, caption: String, title: String, detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title3).foregroundStyle(tint)
                Text(caption).font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            Text(title).font(.title3).fontWeight(.semibold)
            Text(detail)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Keeping the Mac awake

    /// The one thing neither System Settings nor Activity Monitor says
    /// plainly, and now only about applications.
    ///
    /// Settings shows a charge graph and the line "No Apps Using Significant
    /// Energy". Activity Monitor has a Preventing Sleep column that answers
    /// Yes or No. Neither names what is holding it.
    private var awakeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keeping this Mac awake").font(.headline)
                    Text("These are stopping it going to sleep on its own. "
                         + "Quitting one releases it.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(model.appsKeepingMacAwake) { held in
                    HStack(spacing: 10) {
                        ItemIconView(
                            bundleURL: held.bundlePath.map { URL(fileURLWithPath: $0) },
                            role: .unknown, name: held.owner, size: 24
                        )
                        Text(held.owner).fontWeight(.medium)
                        Spacer()
                        Label(held.kind.title, systemImage: held.kind.symbolName)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("\(held.owner), \(held.kind.title)")
                }
            }
        }
    }

    // MARK: - The applications

    private var applicationsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Drawing power now").font(.headline)
                    Spacer()
                    if let busiest = model.busiest, model.applications.count > 1 {
                        Text("\(busiest.name) is using the most")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                if model.applications.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "leaf").foregroundStyle(.green)
                        Text("Nothing you have open is drawing enough power to be worth showing.")
                            .foregroundColor(.secondary)
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                } else {
                    ForEach(model.applications) { reading in
                        row(reading)
                        if reading.id != model.applications.last?.id { Divider() }
                    }
                }

                if let note = model.condition.note {
                    Text(note)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ reading: EnergyModel.Reading) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ItemIconView(
                bundleURL: reading.bundlePath.map { URL(fileURLWithPath: $0) },
                role: ItemIcon.Role.of(reading.identity.kind),
                name: reading.name,
                size: 28
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(reading.name).fontWeight(.medium)
                    Spacer()
                    Text(rate(reading)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    // A bar read against the busiest application, so the
                    // comparison between rows is a shape rather than
                    // arithmetic somebody has to do in their head.
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(3, geometry.size.width * model.share(of: reading)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 5)
                    Text(behaviour(reading))
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 215, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(reading.name)
        .accessibilityValue(SpokenText.sentences([rate(reading), behaviour(reading)]))
    }

    // MARK: - Words and numbers

    /// Watts once there is a watt to show.
    ///
    /// People have a feel for watts: a lamp, a charger, a laptop. Nobody has
    /// a feel for 1053 milliwatts, and a column of four-digit numbers reads
    /// as precision that is not there.
    private func rate(_ reading: EnergyModel.Reading) -> String {
        let value = reading.milliwatts(over: model.window)
        if value < 0.5 { return "under 1 mW" }
        if value < 1000 { return String(format: "%.0f mW", value) }
        return String(format: "%.1f W", value / 1000)
    }

    /// What it is doing, and how long it spent doing it.
    ///
    /// The wakeup count has gone. It was accurate and useless: 1331 wakeups
    /// in two seconds is ordinary for an Electron app and alarming to read,
    /// and there is nothing anybody can do with the number either way.
    /// "Waking up often" was the part worth saying, and it is still here.
    private func behaviour(_ reading: EnergyModel.Reading) -> String {
        let what = reading.dominantCost(over: model.window).sentence
        guard reading.processorSeconds >= 0.01 else { return what }
        return what + String(format: " · %.2fs of processor", reading.processorSeconds)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
