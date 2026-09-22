import Foundation
import os
import BrimCore

private let log = BrimLog.make("presence")

/// What Brim remembers about the person at the machine.
///
/// Two facts, both deliberately small:
///
/// - **Enrolment.** The owner authenticated once, when Brim was first opened.
///   This is setup, not a gate: nothing is withheld until it happens, and it
///   never happens again.
/// - **Presence.** When someone last proved they were here. Persisted across
///   launches on purpose — `sudo` keeps its timestamp in `/var/db/sudo` for
///   exactly the same reason, and an in-memory version would charge a
///   fingerprint for the first destructive action of every session, which is
///   most of what made this tiring during development.
///
/// Neither fact authorises anything on its own. A plan still has to be
/// reviewed and approved in the UI; this only decides whether a *second*
/// confirmation, from the hardware, is worth asking for.
public actor PresenceStore {

    struct Record: Codable, Sendable {
        var enrolledAt: Date?
        var lastPresence: Date?
    }

    private let storeURL: URL
    private var record: Record

    public init(directoryURL: URL) {
        self.storeURL = directoryURL.appendingPathComponent("presence.json")
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode(Record.self, from: data) {
            self.record = loaded
        } else {
            self.record = Record()
        }
    }

    public var isEnrolled: Bool { record.enrolledAt != nil }

    /// When presence was last proved, or nil if never — or if the record is
    /// dated in the future, which a clock change can produce and which must
    /// not be readable as an unending grace window.
    public var lastPresence: Date? {
        guard let last = record.lastPresence, last <= Date() else { return nil }
        return last
    }

    public func recordEnrolment(at date: Date = Date()) {
        record.enrolledAt = date
        record.lastPresence = date
        persist()
    }

    public func recordPresence(at date: Date = Date()) {
        record.lastPresence = date
        persist()
    }

    /// Used by the tests, and by a future "require me to confirm again"
    /// control in settings.
    public func forgetPresence() {
        record.lastPresence = nil
        persist()
    }

    private func persist() {
        let temporary = storeURL.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: storeURL)
            }
        } catch {
            // Losing this costs one extra prompt, never correctness, so it
            // must not fail an operation the user asked for.
            log.notice("could not persist presence: \(error.localizedDescription)")
        }
    }
}
