import Foundation
import BrimCore

/// Where the restore list goes before the reset runs.
///
/// Persisted rather than held in memory, because the thing it protects
/// against is the reset succeeding and Brim then not being there: a crash,
/// a quit, a person closing the laptop. A list that only existed in the
/// running process is exactly no use at the moment it is needed.
///
/// Keyed by plan, so the list that was shown and approved is the list that
/// gets checked, rather than whatever was captured most recently.
public actor RestoreListStore {
    private let directoryURL: URL
    private let fm = FileManager.default

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private func url(for planId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(planId.uuidString).json")
    }

    /// Writes the list, and only reports success once it is readable back.
    ///
    /// The whole point is that this survives the process, so "I wrote it"
    /// is not the claim worth making. "It is on the disk and it parses" is.
    public func save(_ list: BTMRestoreList, for planId: UUID) throws {
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(list).write(to: url(for: planId), options: .atomic)

        guard load(planId: planId) != nil else {
            throw StoreError.couldNotPersist
        }
    }

    public func load(planId: UUID) -> BTMRestoreList? {
        guard let data = try? Data(contentsOf: url(for: planId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BTMRestoreList.self, from: data)
    }

    public enum StoreError: Error, LocalizedError {
        case couldNotPersist

        public var errorDescription: String? {
            "Brim could not write down what is registered, so it will not reset anything. "
            + "There would be no way to put it back."
        }
    }
}
