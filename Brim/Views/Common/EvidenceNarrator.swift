import Foundation
import FoundationModels

/// The model chooses emphasis only. Brim supplies and renders every fact,
/// so generated output cannot add an owner, a figure, or a removal promise.
@Generable
private struct FactChoice {
    var factNumbers: [Int]
}

@MainActor
final class EvidenceNarrator {
    static let shared = EvidenceNarrator()

    private let model = SystemLanguageModel.default
    private let session = LanguageModelSession(instructions: """
    Choose the most useful numbered facts for a short software storage explanation.
    Return their numbers only. Do not create new facts.
    """)
    private var warmed = false
    private var responding = false

    private init() {}

    func prewarm() {
        guard !warmed, case .available = model.availability else { return }
        warmed = true
        session.prewarm(promptPrefix: Prompt("Choose fact numbers for a short storage explanation."))
    }

    /// Returns nil when the model is unavailable, busy, or gives no valid
    /// choice. The view keeps its deterministic text in exactly that case.
    func choose(from facts: [String], limit: Int = 2) async -> String? {
        guard !facts.isEmpty, !responding,
              case .available = model.availability else { return nil }
        responding = true
        defer { responding = false }

        let numbered = facts.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        do {
            let response = try await session.respond(
                to: "Choose fact numbers for a short storage explanation. "
                    + "Choose up to \(limit) facts from this list:\n\(numbered)",
                generating: FactChoice.self
            )
            var seen = Set<Int>()
            let chosen = response.content.factNumbers
                .filter { $0 > 0 && $0 <= facts.count && seen.insert($0).inserted }
                .prefix(limit)
            guard !chosen.isEmpty else { return nil }
            return chosen.map { facts[$0 - 1] }.joined(separator: " ")
        } catch {
            return nil
        }
    }
}
