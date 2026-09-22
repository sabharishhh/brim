import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What is costing you battery, and what that means.
///
/// Measured across a gap between two samples rather than read once. A single
/// reading gives what a process has used since it launched, which makes
/// anything running since login look enormous and anything started a minute
/// ago look asleep. The difference between two samples says what is costing
/// you something now.
///
/// The panel shows two different facts and keeps them apart. **Right now**
/// is a rate, in milliwatts. **Since counting started** is an amount, in
/// milliwatt-hours, from the ledger. They used to sit in two adjacent lists
/// both labelled mWh, which is why three rows looked duplicated.
///
/// It also separates what a person can act on from what they cannot. The
/// five largest consumers on a normal Mac are macOS indexing, analysing
/// photos and predicting for Siri, and a list that puts those in the same
/// column as Figma invites somebody to try to quit one.
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
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Sample again") { Task { await model.sample(service: service) } }
                .disabled(model.isSampling)
        }
        .padding()
    }

    private var subtitle: String {
        if model.isSampling { return "Taking two readings a couple of seconds apart…" }
        if model.readings.isEmpty { return "Nothing drew enough power to measure." }
        return "Measured over \(Int(model.window.rounded())) seconds, just now."
    }

    @ViewBuilder
    private var content: some View {
        if model.isSampling && model.readings.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Watching what the Mac does for a couple of seconds.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.readings.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "leaf").font(.largeTitle).foregroundColor(.green)
                Text("Quiet").font(.headline)
                Text("Nothing is drawing enough power to be worth showing.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 16) {
                        insightCard
                        if !model.assertions.held.isEmpty { awakeCard }
                        splitCard
                        if !model.yours.isEmpty {
                            list("Your software", model.yours, note:
                                 "Things you launched. Quitting one of these is the way to stop it.")
                        }
                        if !model.macOS.isEmpty {
                            list("macOS", model.macOS, note:
                                 "Services the Mac runs for itself, and on behalf of whatever "
                                 + "asked them to. A busy one here is usually a symptom rather "
                                 + "than a cause, and most of them finish on their own.")
                        }
                        if !model.accumulated.isEmpty { totalsCard }
                        if let coverage = model.insight.coverageSentence {
                            Text(coverage)
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(20)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Cards

    /// The sentence at the top, which is the whole panel in one line.
    ///
    /// Deterministic today, from `EnergyInsight`. Every number in it is one
    /// Brim measured, which is what lets T-7.6 hand the same structure to
    /// the on-device model without the model asserting anything new.
    private var insightCard: some View {
        let insight = model.insight
        return card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.title3).foregroundStyle(.yellow)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(insight.sentence)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let busiest = model.busiest {
                        busiestRow(busiest)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func busiestRow(_ reading: EnergyModel.Reading) -> some View {
        HStack(spacing: 8) {
            ItemIconView(
                bundleURL: reading.bundlePath.map { URL(fileURLWithPath: $0) },
                role: ItemIcon.Role.of(reading.identity.kind),
                name: reading.name,
                size: 22
            )
            Text(reading.name).fontWeight(.medium)
            Text(rate(reading))
                .foregroundColor(.secondary).monospacedDigit()
            Spacer()
        }
        .font(.caption)
    }

    /// Where the draw is going, in one bar. Two numbers, never collapsed
    /// into one, because "your software" and "the Mac" are different facts
    /// and a single total hides which is which.
    private var splitCard: some View {
        let yours = model.milliwatts(of: model.yours)
        let system = model.milliwatts(of: model.macOS)
        let total = max(yours + system, 0.0001)

        return card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Where the power is going").font(.headline)
                    Spacer()
                    Text(milliwatts(yours + system))
                        .font(.callout).monospacedDigit().foregroundColor(.secondary)
                }

                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geometry.size.width * (yours / total))
                        Rectangle().fill(Color.secondary.opacity(0.45))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 8)
                .accessibilityHidden(true)

                HStack(spacing: 16) {
                    legend(Color.accentColor, "Your software", yours, model.yours.count)
                    legend(Color.secondary.opacity(0.45), "macOS", system, model.macOS.count)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(
            "Where the power is going. Your software \(milliwatts(yours)) across "
            + "\(model.yours.count) items. macOS \(milliwatts(system)) across "
            + "\(model.macOS.count) items."
        )
    }

    private func legend(_ colour: Color, _ title: String, _ value: Double, _ count: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(title).font(.caption)
            Text(milliwatts(value)).font(.caption).monospacedDigit()
                .foregroundColor(.secondary)
            Text(count == 1 ? "1 item" : "\(count) items")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private func list(_ title: String, _ readings: [EnergyModel.Reading], note: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(note).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(readings) { reading in
                    row(reading)
                    if reading.id != readings.last?.id { Divider() }
                }
            }
        }
    }

    /// Everything since counting started, which is the other question: not
    /// what is busy now, but what has cost the most over days.
    private var totalsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Since \(Self.started.string(from: model.totals?.since ?? Date()))")
                            .font(.headline)
                        Spacer()
                        if let share = model.accumulatedShareOfACharge {
                            Text("\(percent(share)) of a charge")
                                .font(.callout).monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    Text("Added up over every reading Brim has taken, not just this one. "
                         + "The figures on the right are shares of one full charge.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(topTotals) { total in
                    HStack(spacing: 10) {
                        ItemIconView(
                            bundleURL: total.identity.bundlePath.map { URL(fileURLWithPath: $0) },
                            role: ItemIcon.Role.of(total.identity.kind),
                            name: total.name,
                            size: 20
                        )
                        Text(total.name)
                        if !total.identity.kind.isActionable {
                            Text(total.identity.kind.label).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(total.identity.kind.isActionable
                                      ? Color.accentColor.opacity(0.65)
                                      : Color.secondary.opacity(0.4))
                                .frame(width: max(2, geometry.size.width * model.share(of: total)))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 120, height: 6)
                        .accessibilityHidden(true)
                        Text(charge(total.milliwattHours))
                            .monospacedDigit().foregroundColor(.secondary)
                            .frame(width: 96, alignment: .trailing)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(
                        "\(total.name), \(charge(total.milliwattHours)) of a full charge"
                    )
                }
            }
        }
    }

    /// The ten that matter. A list of everything is a list of nothing.
    private var topTotals: [EnergyModel.Total] {
        Array(model.accumulated.filter { $0.milliwattHours >= 1 }.prefix(10))
    }

    static let started: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Rows

    private func row(_ reading: EnergyModel.Reading) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ItemIconView(
                bundleURL: reading.bundlePath.map { URL(fileURLWithPath: $0) },
                role: ItemIcon.Role.of(reading.identity.kind),
                name: reading.name,
                size: 26
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reading.name).fontWeight(.medium)
                    if reading.processCount > 1 {
                        Text("\(reading.processCount) processes").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(rate(reading)).monospacedDigit()
                }

                // What it is doing, then the arithmetic behind the rate.
                Text(behaviour(reading))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let explanation = reading.identity.explanation {
                    Text(explanation)
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(reading.identity.kind.isActionable
                              ? Color.accentColor.opacity(0.65)
                              : Color.secondary.opacity(0.45))
                        .frame(width: max(2, geometry.size.width * share(of: reading)))
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        // One element per application. Left alone the name, the process
        // count and what it cost arrived as three unrelated fragments,
        // and the bar was already hidden because a bar says nothing out
        // loud.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(SpokenText.sentences([
            reading.name,
            reading.processCount > 1 ? "\(reading.processCount) processes" : "",
            reading.identity.explanation ?? ""
        ]))
        .accessibilityValue(SpokenText.sentences([rate(reading), behaviour(reading)]))
    }

    private func share(of reading: EnergyModel.Reading) -> Double {
        let top = model.readings.first?.milliwattHours ?? 1
        return top > 0 ? reading.milliwattHours / top : 0
    }

    // MARK: - Words and numbers

    /// The rate, in milliwatts, which is the honest way to state a reading
    /// taken across a two second window.
    ///
    /// Deliberately not a projection: how long the battery lasts depends on
    /// what the machine does next, which nobody knows, and a figure in
    /// minutes reads as a promise.
    private func rate(_ reading: EnergyModel.Reading) -> String {
        milliwatts(reading.milliwatts(over: model.window))
    }

    /// Watts once there is a watt to show.
    ///
    /// People have a feel for watts: a lamp, a charger, a laptop. Nobody has
    /// a feel for 1053 milliwatts, and a column of four-digit numbers reads
    /// as precision that is not there. Under a watt the milliwatt figure is
    /// the readable one, so the unit changes where the numbers do.
    private func milliwatts(_ value: Double) -> String {
        if value < 0.5 { return "under 1 mW" }
        if value < 1000 { return String(format: "%.0f mW", value) }
        return String(format: "%.1f W", value / 1000)
    }

    /// What the process was actually doing, said as behaviour and then
    /// backed by the counters, so the figure can be checked rather than
    /// taken on trust.
    private func behaviour(_ reading: EnergyModel.Reading) -> String {
        var parts = [reading.dominantCost(over: model.window).sentence]
        if reading.processorSeconds >= 0.01 {
            parts.append(String(format: "%.2fs of processor", reading.processorSeconds))
        }
        if reading.wakeups > 0 {
            parts.append("\(reading.wakeups) \(reading.wakeups == 1 ? "wakeup" : "wakeups")")
        }
        if reading.bytesMoved > 0 {
            parts.append(ByteText.short(Int64(reading.bytesMoved)) + " read or written")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - The card nothing else shows

extension EnergyView {

    /// What is holding sleep off, which is the commonest reason a battery is
    /// flat in the morning and the thing neither System Settings nor
    /// Activity Monitor says plainly. Settings shows a charge graph and the
    /// line "No Apps Using Significant Energy"; Activity Monitor has a
    /// Preventing Sleep column that answers Yes or No.
    var awakeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keeping this Mac awake").font(.headline)
                    if let sentence = model.assertions.sentence {
                        Text(sentence).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(model.assertions.held) { held in
                    HStack(alignment: .top, spacing: 10) {
                        ItemIconView(
                            bundleURL: held.bundlePath.map { URL(fileURLWithPath: $0) },
                            role: held.isYours ? .unknown : .systemService,
                            name: held.owner,
                            size: 22
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(held.owner).fontWeight(.medium)
                                if !held.isYours {
                                    Text("macOS").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                                Spacer()
                                Label(held.kind.title, systemImage: held.kind.symbolName)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            // The name the program gave its own assertion,
                            // which is often the most useful thing on the
                            // row: "com.apple.Music.playback" says exactly
                            // why Music is holding it.
                            if let reason = held.reason {
                                Text(reason).font(.caption2).foregroundColor(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                    }
                    .font(.callout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(SpokenText.sentences([
                        held.owner, held.kind.title, held.isYours ? "" : "part of macOS"
                    ]))
                }

                Text("macOS holds its own while the screen is on or audio is playing. "
                     + "Those follow from whatever asked for them.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A share of a full charge, to one decimal where that means something.
    func charge(_ milliwattHours: Double) -> String {
        guard let battery = model.battery, battery.designMilliwattHours > 0 else {
            return String(format: "%.0f mWh", milliwattHours)
        }
        return percent(milliwattHours / battery.designMilliwattHours)
    }

    func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value < 0.1 { return "under 0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }
}
