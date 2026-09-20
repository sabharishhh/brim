import Foundation
import BrimCore

public struct BTMEnrichedRecord: Sendable {
    public let record: BTMRecord
    public let identity: Identity?
    public let ownerExists: Bool
    
    public init(record: BTMRecord, identity: Identity?, ownerExists: Bool) {
        self.record = record
        self.identity = identity
        self.ownerExists = ownerExists
    }
}

public struct BTMScanner: Sendable {
    private let parser: BTMParser
    private let root: FileSystemRoot
    
    public init(root: FileSystemRoot) {
        self.parser = BTMParser()
        self.root = root
    }
    
    public func scan(dump: String) async -> [BTMEnrichedRecord] {
        let records = parser.parse(dump: dump)
        var enriched = [BTMEnrichedRecord]()
        let resolver = IdentityResolver(root: root)
        let fm = FileManager.default
        
        for record in records {
            var identity: Identity? = nil
            var ownerExists = false
            
            // Resolve identity by URL
            if let url = record.url {
                identity = await resolver.resolve(bundleURL: url)
                if identity?.bundleID == nil {
                    identity = nil
                }
                ownerExists = fm.fileExists(atPath: url.path)
            }
            
            // Resolve identity by bundle identifier if URL fails
            if identity == nil, let bundleID = record.bundleIdentifier {
                identity = Identity(bundleID: bundleID, name: record.name ?? "Unknown")
                ownerExists = record.url.map { fm.fileExists(atPath: $0.path) } ?? false
            }
            
            enriched.append(BTMEnrichedRecord(
                record: record,
                identity: identity,
                ownerExists: ownerExists
            ))
        }
        return enriched
    }
}
