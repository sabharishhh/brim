import BrimCore
import Foundation

/// What an available update changes, for its row on the Updates page.
public struct WhatsNew: Equatable, Sendable {
    public let highlights: [String]
    public let fixesSecurity: Bool
    /// Condensed by the on-device model, rather than shown as written.
    public let isGenerated: Bool

    public init(highlights: [String], fixesSecurity: Bool, isGenerated: Bool) {
        self.highlights = highlights
        self.fixesSecurity = fixesSecurity
        self.isGenerated = isGenerated
    }
}

/// Reads each update's release notes once.
///
/// Short notes are shown as written. Longer ones are condensed by the
/// model, from this version's section only. A CVE identifier marks a
/// security fix without asking anything. Without the model, long notes add
/// nothing to the row: their opening words are usually a heading.
@MainActor
public final class WhatsNewModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case reading
        case ready(WhatsNew)
    }

    @Published public private(set) var states: [String: State] = [:]
    private var asked: Set<String> = []

    public init() {}

    public static func key(_ update: AppUpdate) -> String {
        update.id + "@" + update.latestVersion
    }

    public func state(for update: AppUpdate) -> State? {
        states[Self.key(update)]
    }

    public func read(_ update: AppUpdate, engine: IntelligenceEngine?) async {
        let key = Self.key(update)
        guard !asked.contains(key), let notes = update.releaseNotes, !notes.isEmpty else { return }
        asked.insert(key)
        let section = ReleaseNotesText.section(of: notes, version: update.latestVersion)
        let cve = ReleaseNotesText.mentionsCVE(section)
        if ReleaseNotesText.isShort(section) {
            states[key] = .ready(WhatsNew(highlights: [section], fixesSecurity: cve, isGenerated: false))
            return
        }
        let securityOnly: State? = cve ? .ready(WhatsNew(highlights: [], fixesSecurity: true, isGenerated: false)) : nil
        guard let engine, await engine.availability() == .ready else {
            states[key] = securityOnly
            return
        }
        states[key] = .reading
        switch await engine.highlights(notes: section, version: update.latestVersion) {
        case let .done(reading) where !reading.highlights.isEmpty || reading.fixesSecurity:
            states[key] = .ready(WhatsNew(highlights: reading.highlights,
                                          fixesSecurity: reading.fixesSecurity || cve, isGenerated: true))
        default:
            states[key] = securityOnly
            // Asked again next time the row appears; a refusal is
            // remembered by the engine, so that costs nothing.
            asked.remove(key)
        }
    }
}
