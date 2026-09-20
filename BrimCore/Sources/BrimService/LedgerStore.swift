import Foundation
import BrimCore

public actor LedgerStore {
    private let directoryURL: URL
    private let fm = FileManager.default
    
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }
    
    public func ensureDirectory() throws {
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    
    public func write(entry: LedgerEntry) throws {
        try ensureDirectory()
        let fileURL = directoryURL.appendingPathComponent("\(entry.planId.uuidString).json")
        let data = try JSONEncoder().encode(entry)
        try data.write(to: fileURL, options: .atomic)
    }
    
    public func allEntries() throws -> [LedgerEntry] {
        guard fm.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        var entries: [LedgerEntry] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let entry = try? JSONDecoder().decode(LedgerEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.executedAt > $1.executedAt } // Newest first
    }
}
