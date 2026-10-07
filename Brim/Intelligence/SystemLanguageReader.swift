import BrimCore
import BrimUI
import Foundation
import FoundationModels
import SwiftUI

/// The on-device model behind `LanguageReader`, and the only code in Brim
/// that imports FoundationModels.
///
/// Each request is a fresh, small session with greedy sampling, so the
/// same text always gives the same answer and the cache stays consistent.
/// Inputs are fitted to the context window before they are sent, and every
/// framework error is turned into the `ModelFailure` the engine acts on.
/// Not on the main actor: requests run on the engine's actor.
nonisolated struct SystemLanguageReader: LanguageReader {
    static let enabledKey = "intelligence.enabled"

    func availability() async -> ModelAvailability {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return .offInBrim }
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .preparing
        case .unavailable: return .notSupported
        }
    }

    func prewarm(for question: ModelQuestion) async {
        let instructions = switch question {
        case .releaseNotes: Self.releaseInstructions
        case .installScript: Self.scriptInstructions
        }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    // MARK: - Release notes

    @Generable
    struct ReleaseReading {
        @Guide(
            description: """
            The most noticeable specific changes in this version, most important first. Each at most seven \
            words, starting with a verb such as Adds, Fixes or Improves. No emoji, no version numbers, no \
            names of people.
            """,
            .count(1 ... 3)
        )
        var highlights: [String]
        @Guide(description: "True only if the notes say this version fixes a security issue or vulnerability")
        var fixesSecurity: Bool
    }

    static let releaseInstructions = """
    You read an app's release notes and report what changed in one version. Notes often repeat earlier \
    versions below the new one; ignore those. Use only what the notes say.
    """

    func highlights(notes: String, version: String, tighter: Bool) async throws -> ReleaseHighlights {
        let text = try await fit(notes, reserving: tighter ? 2400 : 700)
        let reading = try await respond(
            instructions: Self.releaseInstructions, prompt: "Version: \(version)\nRelease notes:\n\(text)",
            generating: ReleaseReading.self, maximumTokens: 160
        )
        return ReleaseHighlights(
            highlights: Self.tidy(reading.highlights, limit: 60), fixesSecurity: reading.fixesSecurity
        )
    }

    // MARK: - Install scripts

    @Generable
    struct ScriptReading {
        @Guide(description: "One entry for each requested line, in the order asked")
        var lines: [LineDescription]
        @Guide(description: """
        One or two short sentences for someone who has never seen a script, saying what installing this \
        changes on their Mac. Start with the most significant changes listed by Brim, such as anything that \
        runs in the background, trusts a certificate, downloads files or deletes files. Everyday words. Do not \
        say why, or whether it is good, safe or needed. No commands, file paths, variable names or words such \
        as daemon, launchd, shell, sudo or chmod. Call a certificate a certificate. Name the app if the script does.
        """)
        var summary: String
    }

    @Generable
    struct LineDescription {
        @Guide(description: "The requested line number")
        var line: Int
        @Guide(description: """
        At most nine everyday words saying what the line does to the Mac. No commands, file paths, variable \
        names or technical terms.
        """)
        var words: String
    }

    static let scriptInstructions = """
    You explain what a macOS installer script does, for someone who is not technical and has never read a \
    script. Describe only what each requested line does, in everyday words. Use the rest of the script only \
    to work out names, such as what a variable holds. Do not say whether anything is safe.
    """

    func describe(lines: [Int], of script: String, tighter: Bool) async throws -> ScriptDescription {
        let numbered = try await numberedScript(script, around: lines, tighter: tighter)
        let asked = lines.map(String.init).joined(separator: ", ")
        let changes = InstallScriptReading.consequences(of: InstallScriptReading.findings(in: script))
            .map(\.plain).joined(separator: "; ")
        let reading = try await respond(
            instructions: Self.scriptInstructions,
            prompt: "\(numbered)\n\nChanges Brim found, most significant first: \(changes)"
                + "\n\nDescribe these lines: \(asked)",
            generating: ScriptReading.self, maximumTokens: 40 * lines.count + 120
        )
        var described: [Int: String] = [:]
        for entry in reading.lines where lines.contains(entry.line) && described[entry.line] == nil {
            if let words = Self.tidy([entry.words], limit: 90).first {
                described[entry.line] = words
            }
        }
        let summary = reading.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptDescription(summary: summary.isEmpty || summary.count > 280 ? nil : summary, lines: described)
    }

    /// The script with line numbers, whole if it fits, otherwise only the
    /// asked-for lines with three lines either side. A tighter attempt
    /// never sends the whole script and leaves more room.
    private func numberedScript(_ script: String, around lines: [Int], tighter: Bool) async throws -> String {
        let reserve = tighter ? 2500 : 900
        let all = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let whole = all.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        if !tighter, try await tokens(whole) <= budget(reserving: reserve) {
            return whole
        }
        let wanted = Set(lines.flatMap { ($0 - 3) ... ($0 + 3) }).filter { (1 ... all.count).contains($0) }
        var parts: [String] = []
        var previous = 0
        for number in wanted.sorted() {
            if number != previous + 1 {
                parts.append("…")
            }
            parts.append("\(number): \(all[number - 1])")
            previous = number
        }
        return try await fit(parts.joined(separator: "\n"), reserving: reserve)
    }

    // MARK: - Asking

    private func respond<Content: Generable>(
        instructions: String, prompt: String, generating _: Content.Type, maximumTokens: Int
    ) async throws -> Content {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumTokens)
        do {
            return try await session.respond(to: prompt, generating: Content.self, options: options).content
        } catch let error as LanguageModelError {
            throw Self.failure(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelFailure.other
        }
    }

    /// What each framework error means for the next attempt. Anything
    /// else, such as output that could not be decoded, is a plain failure
    /// and is asked again on the next visit.
    static func failure(_ error: LanguageModelError) -> ModelFailure {
        switch error {
        case .rateLimited: .rateLimited
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: .refused
        case .unsupportedGenerationGuide, .unsupportedCapability, .unsupportedTranscriptContent: .unreadable
        case .contextSizeExceeded: .tooLong
        case .timeout: .timedOut
        @unknown default: .other
        }
    }

    // MARK: - Fitting

    private func budget(reserving reserve: Int) -> Int {
        SystemLanguageModel.default.contextSize - reserve
    }

    private func tokens(_ text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }

    /// `text`, cut at a line or word so it fits the window with room for
    /// the instructions and the answer.
    private func fit(_ text: String, reserving reserve: Int) async throws -> String {
        let limit = budget(reserving: reserve)
        let count = try await tokens(text)
        guard count > limit else { return text }
        let keep = Int(Double(text.count) * Double(limit) / Double(count) * 0.9)
        let cut = text.prefix(keep)
        let end = cut.lastIndex(of: "\n") ?? cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end])
    }

    /// Trimmed, without a closing full stop, short enough for a row, and
    /// each said once.
    static func tidy(_ phrases: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        return phrases.compactMap { phrase in
            var text = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "•-*")))
            while text.hasSuffix(".") {
                text.removeLast()
            }
            guard !text.isEmpty, text.count <= limit, seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
    }
}

extension EnvironmentValues {
    /// The one engine, made by the app; nil in previews and tests.
    @Entry var intelligence: IntelligenceEngine?
}
