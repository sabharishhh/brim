import BrimCore
import Foundation

/// The model's words for the lines Brim found in an installer's scripts.
///
/// Brim's own rules choose the lines (`InstallScriptReading`), so nothing
/// the model misses goes missing and every line number is real. The model
/// only describes them, and a description for a line Brim did not ask
/// about is dropped. It never replaces Brim's phrase: a script can try to
/// steer what is said about it.
@MainActor
public final class ScriptLinesModel: ObservableObject {
    /// How many findings a script shows before "and N more".
    public static let shown = 12

    /// Keyed by script, then by line.
    @Published public private(set) var descriptions: [String: [Int: String]] = [:]
    /// A plain summary of each script, keyed by script.
    @Published public private(set) var summaries: [String: String] = [:]
    @Published public private(set) var reading: Set<String> = []

    public init() {}

    public func read(_ scripts: [InstallerPreview.Script], engine: IntelligenceEngine?) async {
        let readable = scripts.filter { $0.text != nil && !$0.findings.isEmpty && descriptions[$0.id] == nil }
        guard let engine, !readable.isEmpty, await engine.availability() == .ready else { return }
        // Every script waiting its turn shows that it is being read, so no
        // row grows later.
        reading.formUnion(readable.map(\.id))
        defer { reading.subtract(readable.map(\.id)) }
        for script in readable {
            guard !Task.isCancelled, let text = script.text else { return }
            let lines = script.findings.prefix(Self.shown).map(\.line)
            let outcome = await engine.describe(lines: lines, of: text)
            reading.remove(script.id)
            if case let .done(reading) = outcome {
                descriptions[script.id] = reading.lines.filter { lines.contains($0.key) }
                summaries[script.id] = reading.summary
            }
        }
    }
}
