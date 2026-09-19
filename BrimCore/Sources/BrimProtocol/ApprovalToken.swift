import Foundation

public struct ApprovalToken: Codable, Equatable, Sendable {
    public let token: String
    
    // The init is marked internal (or we can just keep it public but ensure only the UI mints it)
    // Actually, to satisfy "No API path produces a token", it must not be returned by BrimServiceProtocol.
    // We will ensure it is created via a specific minting function available only to the app.
    public init(token: String) {
        self.token = token
    }
}
