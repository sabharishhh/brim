import BrimProcess
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

    /// Upgrades one cask Homebrew installed. The name comes from Homebrew's own
    /// listing but reaches a subprocess, so its shape is checked first.
    public func upgradeCask(_ name: String) async -> String? {
        guard Self.isPlausibleCaskName(name) else {
            return "\"\(name)\" is not a cask name."
        }
        guard let brew = resolvedBrew else {
            return "Homebrew is not installed."
        }
        // Homebrew may print a lot while updating itself; the runner drains both
        // streams and stops it at a deadline, so a full pipe cannot hang the update.
        let environment = ProcessInfo.processInfo.environment.filter { key, value in
            !key.isEmpty && !key.contains("=") && !(key + value).contains("\0")
        }
        let result: NativeCommandRunner.Result
        do {
            result = try await NativeCommandRunner.run(
                executable: brew, arguments: ["upgrade", "--cask", name], environment: environment,
                timeout: 30 * 60, outputLimit: 64 * 1024
            )
        } catch {
            return error.localizedDescription
        }
        switch result.termination {
        case .exited(0): return nil
        case .timedOut: return "Homebrew did not finish updating \(name) within half an hour."
        case .cancelled: return "The update was stopped."
        case .exited, .signalled: break
        }
        let details = result.stderr
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
