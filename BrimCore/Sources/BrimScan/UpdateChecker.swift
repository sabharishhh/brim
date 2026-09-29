import Foundation
import BrimCore

/// Drives Homebrew for an application it installed, so its own records
/// stay right when the app is updated.
public struct UpdateChecker: Sendable {

    private let brewPath: String
    private let session: URLSession

    public init(
        brewPath: String = "/opt/homebrew/bin/brew",
        session: URLSession = .shared
    ) {
        self.brewPath = brewPath
        self.session = session
    }

    private var resolvedBrew: String? {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: brewPath) { return brewPath }
        if manager.isExecutableFile(atPath: "/usr/local/bin/brew") { return "/usr/local/bin/brew" }
        return nil
    }

    /// Upgrades one cask Homebrew installed. The name is checked for
    /// shape first: it comes from Homebrew's own listing, but it reaches a
    /// subprocess.
    public func upgradeCask(_ name: String) async -> String? {
        guard Self.isPlausibleCaskName(name) else {
            return "\"\(name)\" is not a cask name."
        }
        guard let brew = resolvedBrew else {
            return "Homebrew is not installed."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", name]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: details, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty
            ? "Homebrew could not update \(name)."
            : message.split(separator: "\n").suffix(3).joined(separator: " ")
    }

    public static func isPlausibleCaskName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && !name.hasPrefix("-")
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "@" }
    }
}
