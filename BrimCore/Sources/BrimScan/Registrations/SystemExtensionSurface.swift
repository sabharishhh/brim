import BrimCore
import Foundation

/// System and network extensions: content filters, VPNs, DriverKit drivers.
///
/// These are the ones that survive hardest. A deactivation is owned by the
/// host application, not by whoever happens to be uninstalling it, and
/// macOS will not let a third party withdraw somebody else's extension.
/// A VPN client removed by dragging it to the Trash characteristically
/// leaves a dead network configuration that the person then cannot get
/// rid of from Settings either.
///
/// So this surface reports and routes, and never acts. That is the
/// specification's own wording for B6, and it is right: an action Brim
/// cannot actually carry out is worse than an honest sentence naming what
/// is there and who owns it.
public struct SystemExtensionSurface: RegistrationSurface {
    public let kind: Registration.Kind = .systemExtension

    private let usesSystemTool: Bool
    private let read: @Sendable () -> String?

    public init(read: (@Sendable () -> String?)? = nil) {
        usesSystemTool = read == nil
        self.read = read ?? { ToolOutput.read("/usr/bin/systemextensionsctl", ["list"]) }
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        await snapshot(in: root).coverage
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        if usesSystemTool, root.rootURL.standardizedFileURL.path != "/" {
            return RegistrationSnapshot(registrations: [], coverage: .withheld(
                kind, "The system registration tool is outside this filesystem."
            ))
        }
        guard let output = read() else {
            return RegistrationSnapshot(registrations: [],
                                        coverage: .unavailable(kind, "System extensions could not be read."))
        }
        let records = Self.parse(output)
        let count = output.split(separator: "\n").first { $0.hasSuffix("extension(s)") }
            .flatMap { Int($0.split(separator: " ").first ?? "") }
        let complete = count != nil && count == records.count
        return RegistrationSnapshot(registrations: records, coverage: RegistrationCoverage(
            kind: kind, available: complete,
            limitation: complete ? nil : "The system extension listing could not be fully checked."
        ), readerVersion: 2)
    }

    public func registrations(in _: FileSystemRoot) async -> [Registration] {
        guard let output = read() else { return [] }
        return Self.parse(output)
    }

    /// `systemextensionsctl list` prints a header per category, then one
    /// line per extension, then a count. An empty machine prints only
    /// "0 extension(s)", which is a real answer and not a failure.
    static func parse(_ output: String) -> [Registration] {
        var results: [Registration] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasSuffix("extension(s)") {
                continue
            }
            if line.hasPrefix("---") || line.lowercased().hasPrefix("enabled") {
                continue
            }

            // Columns are tab separated: enabled, active, team, bundle id,
            // version, name, state.
            let fields = line.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard fields.count >= 4 else { continue }

            // The bundle identifier is the first field shaped like one.
            // Each field is reduced to its first token first, because the
            // identifier column carries a version beside it:
            // "com.example.vpn.extension (1.0/1.0)".
            guard let identifier = fields
                .compactMap({ $0.split(separator: " ").first.map(String.init) })
                .first(where: {
                    $0.contains(".") && !$0.hasPrefix("[") && !$0.hasPrefix("*")
                        && $0.rangeOfCharacter(from: .letters) != nil
                })
            else { continue }

            let state = fields.last ?? ""
            let isTerminated = state.lowercased().contains("terminated")
                || state.lowercased().contains("uninstall")

            results.append(Registration(
                kind: .systemExtension,
                identifier: identifier,
                label: identifier,
                owningBundleID: identifier,
                programPath: nil,
                // Nothing here is judged stale. What state an extension is
                // in is macOS's business and the host application's, and
                // guessing from a status string would produce a row
                // offering an action that cannot work.
                targetExists: true,
                recordPath: nil,
                evidence: isTerminated
                    ? "A system extension macOS has marked \(state). Only the application "
                    + "that installed it can withdraw it."
                    : "A system or network extension listed as \(state). Only the application that "
                    + "installed it can withdraw it.",
                isSystemOwned: identifier.hasPrefix("com.apple."),
                capability: .refusedByOS,
                targetPresence: .unknown("The system extension listing does not expose a backing path."),
                recordIdentity: fields.joined(separator: "|"), namespace: "system", runtimeState: state
            ))
        }

        return results
    }
}
