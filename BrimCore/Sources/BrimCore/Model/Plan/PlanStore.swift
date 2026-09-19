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
    
    public func save(plan: Plan) throws {
        try ensureDirectory()
        
        let fileURL = directoryURL.appendingPathComponent("\(plan.planId.uuidString).json")
        let data = try plan.canonicalData()
        
        // Write atomically
        try data.write(to: fileURL, options: .atomic)
    }
    
    public func load(planId: UUID) throws -> Plan {
        let fileURL = directoryURL.appendingPathComponent("\(planId.uuidString).json")
        let data = try Data(contentsOf: fileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            guard let date = formatter.date(from: dateStr) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
            }
            return date
        })
        
        return try decoder.decode(Plan.self, from: data)
    }
}
