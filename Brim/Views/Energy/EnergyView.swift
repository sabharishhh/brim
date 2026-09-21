import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What is costing you battery right now.
///
/// Measured across a gap between two samples rather than read once. A
/// single reading gives what a process has used since it launched, which
/// makes anything running since login look enormous and anything started a
/// minute ago look asleep. The difference between two samples says what is
/// costing you something now.
///
/// One row per application, not per process. A modern Mac app is a crowd
/// of them: ChatGPT runs thirteen and Claude seven, each a renderer, a GPU
/// helper or a network service with its own pid and its own share of the
/// work. Listed separately they filled the view with the same three names
/// and answered nobody's question, because "what is using my battery" is a
/// question about an app.
///
/// The number beside each row is a score, not joules. Nothing on a Mac
/// reports per process energy in physical units, and inventing a figure in
/// watts would be the kind of confident nonsense this app exists to avoid.
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
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Sample again") { Task { await model.sample(service: service) } }
                .disabled(model.isSampling)
        }
        .padding()
    }

    private var summary: String {
        if model.isSampling { return "Watching for a couple of seconds…" }
        if model.readings.isEmpty { return "Nothing was busy while Brim watched." }
        let processes = model.readings.reduce(0) { $0 + $1.processCount }
        var text = "\(model.measured) apps busy over \(Int(model.window.rounded())) seconds"
        if processes > model.measured { text += ", across \(processes) processes" }
        if model.coverageGaps > 0 {
            text += ", and \(model.coverageGaps) that macOS would not let Brim read"
        }
        return text
    }

    @ViewBuilder
    private var content: some View {
        if model.isSampling && model.readings.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Taking two readings a couple of seconds apart, so the number means "
                     + "\"right now\" and not \"since you logged in\".")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.readings.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "leaf").font(.largeTitle).foregroundColor(.green)
                Text("Quiet").font(.headline)
                Text("Nothing did enough work to measure while Brim was watching.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.readings) { reading in
                row(reading, share: share(of: reading))
            }
            .listStyle(.inset)
        }
    }

    private func share(of reading: EnergyModel.Reading) -> Double {
        let top = model.readings.first?.milliwattHours ?? 1
        return top > 0 ? reading.milliwattHours / top : 0
    }

    private func row(_ reading: EnergyModel.Reading, share: Double) -> some View {
        HStack(spacing: 10) {
            if let bundlePath = reading.bundlePath {
                AppIconView(url: URL(fileURLWithPath: bundlePath), size: 26)
            } else {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary).frame(width: 26)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(reading.name).fontWeight(.medium)
                    if reading.bundlePath == nil {
                        Text("background").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    // Said out loud, because the total is the sum of them
                    // and a single row for thirteen processes would
                    // otherwise look like an undercount.
                    if reading.processCount > 1 {
                        Text("\(reading.processCount) processes").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(rate(reading)).font(.caption)
                        .foregroundColor(.secondary).monospacedDigit()
                }
                Text(costs(reading)).font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, geometry.size.width * share))
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
            reading.bundlePath == nil ? "runs in the background" : "",
            reading.processCount > 1 ? "\(reading.processCount) processes" : ""
        ]))
        .accessibilityValue(costs(reading))
    }

    /// Says what the process actually did, rather than showing a score
    /// nobody can check.
    /// What it drew while Brim watched, as a rate.
    ///
    /// Milliwatts, which is energy over time and is the honest way to
    /// state a reading taken across a two second window. Deliberately not
    /// a projection: how long the battery lasts depends on what the
    /// machine does next, which nobody knows, and a figure in minutes
    /// reads as a promise.
    private func rate(_ reading: EnergyModel.Reading) -> String {
        let milliwatts = reading.milliwatts(over: model.window)
        guard milliwatts >= 0.1 else { return "barely anything" }
        return String(format: "%.0f mW", milliwatts)
    }

    /// The arithmetic, shown rather than hidden: this much energy, over
    /// this long, is that rate.
    private func costs(_ reading: EnergyModel.Reading) -> String {
        var parts: [String] = [
            String(format: "%.2f mWh over %.1fs", reading.milliwattHours, model.window)
        ]
        if let share = model.battery?.sentence(forMilliwattHours: reading.milliwattHours) {
            parts.append(share)
        }
        let seconds = Double(reading.cpuNanoseconds) / 1_000_000_000
        if seconds >= 0.01 { parts.append(String(format: "%.2fs of processor", seconds)) }
        if reading.wakeups > 0 { parts.append("\(reading.wakeups) wakeups") }
        if reading.bytesMoved > 0 { parts.append(ByteText.short(Int64(reading.bytesMoved)) + " moved") }
        return parts.joined(separator: ", ")
    }
}
