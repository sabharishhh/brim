import BrimCore
import Foundation

/// Firewall entries name concrete executable paths. Brim reads them and
/// routes changes to Settings until a privileged removal adapter is validated.
public struct FirewallSurface: RegistrationSurface {
    public let kind: Registration.Kind = .firewallEntry
    private let read: @Sendable () -> String?
    private let usesSystemTool: Bool

    public init(read: (@Sendable () -> String?)? = nil) {
        usesSystemTool = read == nil
        self.read = read ?? {
            ToolOutput.read("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--listapps"])
        }
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        await snapshot(in: root).coverage
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        await snapshot(in: root).registrations
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        if usesSystemTool, root.rootURL.standardizedFileURL.path != "/" {
            return RegistrationSnapshot(
                registrations: [],
                coverage: .withheld(kind, "The system firewall is outside this filesystem.")
            )
        }
        guard let output = read() else {
            return RegistrationSnapshot(
                registrations: [],
                coverage: .unavailable(kind, "Firewall entries could not be read.")
            )
        }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let count = lines.first { $0.hasPrefix("Total number of apps =") }
            .flatMap { Int($0.dropFirst("Total number of apps =".count).trimmingCharacters(in: .whitespaces)) }
        let paths = lines.compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ":"),
                  Int(line[..<separator].trimmingCharacters(in: .whitespaces)) != nil else { return nil }
            let path = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? path : nil
        }
        let registrations = paths.map { path in
            Registration(kind: kind, identifier: path, label: URL(fileURLWithPath: path).lastPathComponent,
                         programPath: path, targetExists: true, evidence: "An application firewall entry at this path.",
                         capability: .needsHelper, targetPresence: PathObservation.observe(path), namespace: "system")
        }
        let complete = count != nil && count == paths.count
        return RegistrationSnapshot(registrations: registrations, coverage: RegistrationCoverage(
            kind: kind, available: complete,
            limitation: complete ? nil : "The firewall listing format could not be fully checked."
        ), readerVersion: 1)
    }
}
