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
        var text = "\(model.measured) busy over \(Int(model.window.rounded())) seconds"
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
        let top = Double(model.readings.first?.impact ?? 1)
        return top > 0 ? Double(reading.impact) / top : 0
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
                    Spacer()
                    Text(costs(reading)).font(.caption)
                        .foregroundColor(.secondary).monospacedDigit()
                }
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
    }

    /// Says what the process actually did, rather than showing a score
    /// nobody can check.
    private func costs(_ reading: EnergyModel.Reading) -> String {
        var parts: [String] = []
        let seconds = Double(reading.cpuNanoseconds) / 1_000_000_000
        if seconds >= 0.01 { parts.append(String(format: "%.2fs of processor", seconds)) }
        if reading.wakeups > 0 { parts.append("\(reading.wakeups) wakeups") }
        if reading.bytesMoved > 0 { parts.append(ByteText.short(Int64(reading.bytesMoved)) + " moved") }
        return parts.isEmpty ? "barely anything" : parts.joined(separator: ", ")
    }
}
