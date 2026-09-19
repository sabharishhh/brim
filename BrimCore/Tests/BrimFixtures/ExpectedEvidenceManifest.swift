import Foundation

/// Represents the expected evidence Brim should find for a given fixture app.
public struct ExpectedEvidenceManifest: Codable, Equatable {
    public let bundleID: String
    public let expectedItems: [ExpectedItem]
    
    public struct ExpectedItem: Codable, Equatable {
        public let relativePath: String
        public let tier: String // "A", "B", "C", "S"
        public let description: String
        
        public init(relativePath: String, tier: String, description: String) {
            self.relativePath = relativePath
            self.tier = tier
            self.description = description
        }
    }
    
    public init(bundleID: String, expectedItems: [ExpectedItem]) {
        self.bundleID = bundleID
        self.expectedItems = expectedItems
    }
}
