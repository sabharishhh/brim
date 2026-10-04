import BrimCore
import Darwin
import Foundation

public struct PackageRecordResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case present, absent, unknown }
    public let installation: HomebrewInstallation
    public let state: State

    public var detail: String {
        switch state {
        case .present: "Homebrew's installation record remains. Removing files does not remove it."
        case .absent: "The recorded Homebrew receipt is no longer at its original path."
        case .unknown: "The Homebrew receipt could not be checked. Its removal has not been verified."
        }
    }

    public static func observe(_ installation: HomebrewInstallation) -> Self {
        var info = stat()
        let status = lstat(installation.receiptPath, &info)
        let state: State = status == 0 ? .present : ((errno == ENOENT || errno == ENOTDIR) ? .absent : .unknown)
        return Self(installation: installation, state: state)
    }
}
