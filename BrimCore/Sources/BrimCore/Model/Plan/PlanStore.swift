import Foundation

public actor PlanStore {
    private let directoryURL: URL
    private let fm = FileManager.default
    /// What this process wrote for each plan. The folder belongs to the person,
    /// so any program they run could rewrite a plan on screen. A plan that no
    /// longer matches what was written here, or was never written here, is
    /// refused.
    private var written: [UUID: Data] = [:]

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func ensureDirectory() throws {
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public enum PlanStoreError: Error, LocalizedError {
        case planAlreadyExists
        case changedOnDisk

        public var errorDescription: String? {
            switch self {
            case .planAlreadyExists: "A different plan with this identifier already exists."
            case .changedOnDisk: "The plan was changed after it was made, so it was not used."
            }
        }
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
            written[plan.planId] = data
            return // Same plan, skip write
        }

        // Write atomically
        try data.write(to: fileURL, options: .atomic)
        written[plan.planId] = data
    }

    /// Whether this process wrote the plan and the disk still holds exactly
    /// that. Approval asks this before anything is shown to a person.
    public func isUnchangedSinceWritten(planId: UUID) -> Bool {
        guard let ours = written[planId] else { return false }
        let fileURL = directoryURL.appendingPathComponent("\(planId.uuidString).json")
        return (try? Data(contentsOf: fileURL)) == ours
    }

    /// Read from the disk every time: approval checks the plan still says what
    /// it said when the person was asked, and a copy in memory would never see
    /// it change.
    public func load(planId: UUID) throws -> Plan {
        let fileURL = directoryURL.appendingPathComponent("\(planId.uuidString).json")
        let data = try Data(contentsOf: fileURL)
        if let ours = written[planId], ours != data {
            throw PlanStoreError.changedOnDisk
        }
        return try Self.decoder.decode(Plan.self, from: data)
    }

    /// One decoder, using the date format plans are written with.
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
    /// The one date format plans are written and read in, shared because every
    /// step's fingerprint carries a date. The formatter is documented as safe to
    /// share between threads; Swift cannot see that.
    nonisolated(unsafe) static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
