import Foundation

public struct Leftover: Sendable, Codable, Equatable {
    public enum Category: String, Sendable, Codable, Equatable {
        /// Owner was recorded present and is now gone, or a receipt exists for an absent product.
        case orphaned
        
        /// Residue that Brim cannot attribute to any installed app.
        case unclaimed
    }
    
    public let url: URL
    public let size: Int64
    public let category: Category
    public let potentialOwner: Identity?
    
    public init(url: URL, size: Int64, category: Category, potentialOwner: Identity? = nil) {
        self.url = url
        self.size = size
        self.category = category
        self.potentialOwner = potentialOwner
    }
}
