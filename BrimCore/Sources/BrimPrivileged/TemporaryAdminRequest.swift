import Foundation

/// The temporary process accepts the same bounded operations as the signed helper.
public enum TemporaryAdminRequest: Codable, Sendable {
    case version
    case removeDefunctJob(domain: String, name: String)
    case removeBrokenCommand(domain: String, name: String)
    case forgetReceipt(packageID: String)
    case removeInstalledBundle(domain: String, name: String)
    case removeInstalledPayload(packageID: String, name: String)
    case removeSystemCache(name: String)
    case removeSystemPreference(name: String)
    case recoveryItems
    case removeRecoveryItem(identifier: String, expectedDevice: Int32, expectedInode: UInt64)
    case uninstallSelf
}

public struct TemporaryAdminResponse: Codable, Sendable {
    public let data: Data?
    public let complaint: String?

    public init(data: Data? = nil, complaint: String? = nil) {
        self.data = data
        self.complaint = complaint
    }
}
