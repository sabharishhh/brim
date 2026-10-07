import BrimCore
import BrimProtocol
import Foundation

public enum PlanStatus: String, Codable, Sendable {
    case pending
    case partial
    case completed
    case crashed
    case failed
}

public struct JournalEntry: Codable, Sendable {
    public let planId: UUID
    public let startedAt: Date
    public var status: PlanStatus
    public var stepOutcomes: [Int: String] // Step index -> Error reason or "ok"
    public var stepTrashedURLs: [Int: URL]? // Step index -> URL in Trash
    public var freeSpaceBefore: Int64?
    public var freeSpaceAfter: Int64?
    public var verifications: [VerificationResult]?
    /// Absent in legacy journals and until every requested restore finishes.
    public var restoredAt: Date?
    /// Restoration receipts never replace the original execution outcomes.
    public var restoreOutcomes: [Int: String]?

    public init(
        planId: UUID,
        startedAt: Date,
        status: PlanStatus,
        stepOutcomes: [Int: String] = [:],
        stepTrashedURLs: [Int: URL]? = nil,
        freeSpaceBefore: Int64? = nil,
        freeSpaceAfter: Int64? = nil,
        restoredAt: Date? = nil,
        restoreOutcomes: [Int: String]? = nil
    ) {
        self.planId = planId
        self.startedAt = startedAt
        self.status = status
        self.stepOutcomes = stepOutcomes
        self.stepTrashedURLs = stepTrashedURLs
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
        verifications = nil
        self.restoredAt = restoredAt
        self.restoreOutcomes = restoreOutcomes
    }
}

public actor JournalStore {
    private let directoryURL: URL
    private let fileManager = FileManager.default

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Keep startup work bounded even after years of removal history.
    /// Older removals remain available through Journal's Check removal action.
    func recentEntries(limit: Int = 100) throws -> [JournalEntry] {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let recent = urls.filter { $0.pathExtension == "journal" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(max(0, limit))
        return recent.compactMap { url, _ in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(JournalEntry.self, from: data)
        }
    }

    private func fileURL(for planId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(planId.uuidString).journal")
    }

    public func write(entry: JournalEntry) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(entry)
        try data.write(to: fileURL(for: entry.planId), options: .atomic)
    }

    public func load(planId: UUID) throws -> JournalEntry? {
        let url = fileURL(for: planId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JournalEntry.self, from: data)
    }

    /// Append an observation without overwriting execution receipts or keeping approvals.
    public func recordVerification(_ result: VerificationResult) throws {
        guard var latest = try load(planId: result.planId) else { return }
        latest.verifications = (latest.verifications ?? []) + [result]
        try write(entry: latest)
    }

    /// Update the latest journal without replacing execution or verification receipts.
    public func recordRestoreOutcome(planId: UUID, stepIndex: Int, outcome: String) throws {
        var latest = try restorationEntry(planId: planId)
        var outcomes = latest.restoreOutcomes ?? [:]
        outcomes[stepIndex] = outcome
        latest.restoreOutcomes = outcomes
        try write(entry: latest)
    }

    /// Completion is separate from individual receipts so a failed restore can resume.
    public func markRestored(planId: UUID, at date: Date) throws {
        var latest = try restorationEntry(planId: planId)
        guard latest.restoredAt == nil else { return }
        latest.restoredAt = date
        try write(entry: latest)
    }

    private func restorationEntry(planId: UUID) throws -> JournalEntry {
        guard let latest = try load(planId: planId) else {
            throw NSError(domain: "BrimJournal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The restoration could not be recorded because its journal is missing."
            ])
        }
        return latest
    }
}
