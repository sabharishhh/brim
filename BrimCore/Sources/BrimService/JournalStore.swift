import Foundation
import BrimCore

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
    
    public init(planId: UUID, startedAt: Date, status: PlanStatus, stepOutcomes: [Int : String] = [:], stepTrashedURLs: [Int: URL]? = nil, freeSpaceBefore: Int64? = nil, freeSpaceAfter: Int64? = nil) {
        self.planId = planId
        self.startedAt = startedAt
        self.status = status
        self.stepOutcomes = stepOutcomes
        self.stepTrashedURLs = stepTrashedURLs
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
    }
}

public actor JournalStore {
    private let directoryURL: URL
    private let fm = FileManager.default
    
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }
    
    public func ensureDirectory() throws {
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    
    public func allPlanIds() throws -> [UUID] {
        try ensureDirectory()
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return urls.compactMap { url in
            guard url.pathExtension == "journal" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }
    
    private func fileURL(for planId: UUID) -> URL {
        return directoryURL.appendingPathComponent("\(planId.uuidString).journal")
    }
    
    public func write(entry: JournalEntry) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(entry)
        try data.write(to: fileURL(for: entry.planId), options: .atomic)
    }
    
    public func load(planId: UUID) throws -> JournalEntry? {
        let url = fileURL(for: planId)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JournalEntry.self, from: data)
    }
    
    public func getOpenJournals() throws -> [JournalEntry] {
        try ensureDirectory()
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        var entries = [JournalEntry]()
        for url in urls where url.pathExtension == "journal" {
            let data = try Data(contentsOf: url)
            if let entry = try? JSONDecoder().decode(JournalEntry.self, from: data) {
                if entry.status == .pending || entry.status == .partial {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    public func delete(planId: UUID) throws {
        let url = fileURL(for: planId)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
