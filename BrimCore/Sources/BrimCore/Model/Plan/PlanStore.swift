import Foundation

public actor PlanStore {
    private let directoryURL: URL
    private let fm = FileManager.default

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func ensureDirectory() throws {
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public enum PlanStoreError: Error {
        case planAlreadyExists
    }

    public func save(plan: Plan) throws {
        try ensureDirectory()

        let fileURL = directoryURL.appendingPathComponent("\(plan.planId.uuidString).json")
        let data = try plan.canonicalData()

        if fm.fileExists(atPath: fileURL.path) {
            let existingData = try Data(contentsOf: fileURL)
            if existingData != data {
                throw PlanStoreError.planAlreadyExists
            }
            return // Same plan, skip write
        }

        // Write atomically
        try data.write(to: fileURL, options: .atomic)
    }

    /// Read from the disk every time, never remembered: approval checks
    /// that the plan still says what it said when the person was asked, and
    /// a copy held in memory would never see it change.
    public func load(planId: UUID) throws -> Plan {
        let fileURL = directoryURL.appendingPathComponent("\(planId.uuidString).json")
        return try Self.decoder.decode(Plan.self, from: Data(contentsOf: fileURL))
    }

    /// One formatter for every date, the one plans are written with. It
    /// was built inside the decoding closure, so a new ISO 8601 formatter
    /// for each date of each plan read.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            guard let date = Plan.dates.date(from: dateStr) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
            }
            return date
        }
        return decoder
    }()
}

extension Plan {
    /// The one date format plans are written and read in. It was a new
    /// formatter for every date, and every step's fingerprint carries one,
    /// so hashing a plan of a few thousand steps, which a removal does
    /// several times, built a few thousand formatters. The formatter is
    /// documented as safe to share between threads; Swift cannot see that.
    nonisolated(unsafe) static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
