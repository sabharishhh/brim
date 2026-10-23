import Foundation
import os
import BrimCore

private let log = BrimLog.make("presence")

/// What Brim remembers about the person at the Mac:
/// - Enrolment: the owner authenticated once, at first launch. Setup, not a
///   gate.
/// - Presence: when someone last proved they were here.
/// Neither authorises anything. A plan is still reviewed and approved in the
/// window; this only decides whether a hardware confirmation is worth
/// asking for.
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
           var loaded = try? JSONDecoder().decode(Record.self, from: data) {
            // Enrolment carries over; the last fingerprint does not. The file is the
            // person's, so any program can write it, and a time written before launch
            // would skip the prompt for a permanent deletion. A grace window starts
            // with a prompt in this run, never from the disk.
            loaded.lastPresence = nil
            self.record = loaded
        } else {
            self.record = Record()
        }
    }

    public var isEnrolled: Bool { record.enrolledAt != nil }

    /// When presence was last proved, or nil if never or if dated in the future,
    /// which a clock change can produce and which must not read as an unending
    /// grace window.
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

    public func forgetPresence() {
        record.lastPresence = nil
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: storeURL, options: .atomic)
        } catch {
            // Losing this costs one extra prompt, never correctness, so it must not
            // fail an operation.
            log.notice("could not persist presence: \(error.localizedDescription)")
        }
    }
}
