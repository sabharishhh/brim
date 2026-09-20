import Foundation

public struct BTMRecord: Equatable, Sendable {
    public let uuid: String
    public let name: String?
    public let developerName: String?
    public let type: String?
    public let disposition: String?
    public let identifier: String?
    public let url: URL?
    public let bundleIdentifier: String?
    
    public init(uuid: String, name: String?, developerName: String?, type: String?, disposition: String?, identifier: String?, url: URL?, bundleIdentifier: String?) {
        self.uuid = uuid
        self.name = name
        self.developerName = developerName
        self.type = type
        self.disposition = disposition
        self.identifier = identifier
        self.url = url
        self.bundleIdentifier = bundleIdentifier
    }
}
