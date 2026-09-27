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
    private static let instructions = """
    Choose the most useful numbered facts for a short software storage explanation.
    Return their numbers only. Do not create new facts.
    """
    private var session: LanguageModelSession?
    private var responding = false
    private struct ChoiceKey: Hashable {
        let facts: [String]
        let limit: Int
    }

    private var choices: [ChoiceKey: String] = [:]
    private var choiceOrder: [ChoiceKey] = []

    private init() {}

    func prewarm() {
        guard session == nil, case .available = model.availability else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        self.session = session
        session.prewarm(promptPrefix: Prompt("Choose fact numbers for a short storage explanation."))
    }

    /// Returns nil when the model is unavailable, busy, or gives no valid
    /// choice. The view keeps its deterministic text in exactly that case.
    func choose(from facts: [String], limit: Int = 2) async -> String? {
        guard limit > 0, !facts.isEmpty, !Task.isCancelled else { return nil }
        if facts.count <= limit {
            return facts.joined(separator: " ")
        }
        let key = ChoiceKey(facts: facts, limit: limit)
        if let cached = choices[key] {
            return cached
        }
        guard facts.count <= 16, facts.reduce(0, { $0 + $1.utf8.count }) <= 6000,
              !responding,
              case .available = model.availability else { return nil }
        prewarm()
        guard let session else { return nil }
        responding = true
        // Each explanation is independent. Release its transcript instead
        // of accumulating unrelated requests until the context is full.
        defer { responding = false; self.session = nil }

        let numbered = facts.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        do {
            let response = try await session.respond(
                to: "Choose fact numbers for a short storage explanation. "
                    + "Choose up to \(limit) facts from this list:\n\(numbered)",
                generating: FactChoice.self
            )
            guard !Task.isCancelled else { return nil }
            var seen = Set<Int>()
            let chosen = response.content.factNumbers
                .filter { $0 > 0 && $0 <= facts.count && seen.insert($0).inserted }
                .prefix(limit)
            guard !chosen.isEmpty else { return nil }
            let result = chosen.map { facts[$0 - 1] }.joined(separator: " ")
            if choiceOrder.count == 32 {
                choices.removeValue(forKey: choiceOrder.removeFirst())
            }
            choiceOrder.append(key)
            choices[key] = result
            return result
        } catch {
            return nil
        }
    }
}
