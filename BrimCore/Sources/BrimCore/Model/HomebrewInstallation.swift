import Darwin
import Foundation

/// An installation record for this exact application path. Removing files
/// through Brim does not remove this package manager record.
public struct HomebrewInstallation: Codable, Equatable, Sendable {
    public let token: String
    public let applicationPath: String
    public let receiptPath: String

    public init?(token: String, applicationPath: String, receiptPath: String) {
        guard Self.isValidToken(token), applicationPath.hasPrefix("/"), receiptPath.hasPrefix("/"),
              !applicationPath.contains("\0"), !receiptPath.contains("\0") else { return nil }
        self.token = token
        self.applicationPath = applicationPath
        self.receiptPath = receiptPath
    }

    /// For the person to run outside Brim. This is never an execution step.
    public var manualCommand: String? {
        guard Self.isValidToken(token) else { return nil }
        let suffix = "/Caskroom/\(token)/.metadata/INSTALL_RECEIPT.json"
        guard receiptPath.hasSuffix(suffix) else { return nil }
        let prefix = String(receiptPath.dropLast(suffix.count))
        guard prefix.hasPrefix("/"), !prefix.contains("\0"),
              prefix.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
              .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let executable = URL(fileURLWithPath: prefix).appendingPathComponent("bin/brew")
        var information = stat()
        guard stat(executable.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "\(quoted) uninstall --cask \(token)"
    }

    public var explanation: String {
        "Homebrew records this app as \(token). Brim removes the selected files; its Homebrew record remains."
    }

    public static func isValidToken(_ token: String) -> Bool {
        guard let first = token.utf8.first, (97 ... 122).contains(first) || (48 ... 57).contains(first),
              token.utf8.count <= 200 else { return false }
        return token.utf8.allSatisfy {
            (97 ... 122).contains($0) || (48 ... 57).contains($0) || [45, 46, 95, 43, 64].contains($0)
        }
    }
}
