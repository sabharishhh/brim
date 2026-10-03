import BrimCore
import BrimOps
import Foundation

/// A profile can mention an app without belonging exclusively to it.
/// Detection never grants removal authority over the profile or its payloads.
public struct ConfigurationProfileSurface: RegistrationSurface {
    public let kind: Registration.Kind = .configurationProfile
    private let read: @Sendable () async -> Data?
    private let usesSystemTool: Bool

    public init(read: (@Sendable () async -> Data?)? = nil) {
        usesSystemTool = read == nil
        self.read = read ?? {
            guard let result = try? await NativeCommandRunner.run(
                executable: "/usr/bin/profiles", arguments: ["show", "-type", "configuration", "-output", "stdout-xml"],
                environment: ["LC_ALL": "C"], timeout: 10, outputLimit: 1024 * 1024
            ), result.termination == .exited(0), !result.outputTruncated else { return nil }
            return result.stdout
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
            return RegistrationSnapshot(registrations: [], coverage: .withheld(
                kind, "Management profiles are outside this filesystem."
            ))
        }
        guard let data = await read(), data.count <= 1024 * 1024,
              let stores = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return unreadable() }
        var records: [Registration] = []
        // profiles(1) scopes non-root output to the requesting user. Even
        // valid empty XML cannot establish that device-level policy is absent.
        for namespace in stores.keys.sorted() {
            guard let profiles = stores[namespace] as? [[String: Any]] else { return unreadable() }
            for profile in profiles {
                guard let identifier = profile["ProfileIdentifier"] as? String, !identifier.isEmpty,
                      let uuid = profile["ProfileUUID"] as? String, !uuid.isEmpty,
                      let items = profile["ProfileItems"] as? [[String: Any]]
                else { return unreadable() }
                let label = profile["ProfileDisplayName"] as? String ?? identifier
                for client in Self.clients(in: items).sorted(by: { $0.sortKey < $1.sortKey }) {
                    records.append(Registration(
                        kind: kind, identifier: identifier, label: label, owningBundleID: client.bundleID,
                        programPath: client.path,
                        targetExists: true,
                        evidence: "A configuration profile references \(client.value). "
                            + "The profile may include other applications or settings.",
                        capability: .refusedByOS,
                        targetPresence: .unknown(
                            "Profile presence does not establish that the referenced app is installed."
                        ),
                        recordIdentity: uuid + ":" + client.identity, namespace: namespace,
                        runtimeState: "Policy reference; removal authority not established",
                        rawTargetPath: client.path
                    ))
                }
            }
        }
        return RegistrationSnapshot(registrations: records, coverage: .unavailable(
            kind, "Only returned profile references were inspected. "
                + "Device-level policy, other accounts, declarative policy and unrecognized payloads "
                + "could not be fully checked."
        ), readerVersion: 2)
    }

    private func unreadable() -> RegistrationSnapshot {
        RegistrationSnapshot(registrations: [], coverage: .unavailable(
            kind, "Management profiles could not be read or their listing format was unsupported."
        ))
    }

    private enum Client: Hashable {
        case bundle(String)
        case binaryPath(String)

        var value: String {
            switch self {
            case let .bundle(value), let .binaryPath(value): value
            }
        }

        var bundleID: String? {
            if case let .bundle(value) = self {
                value
            } else {
                nil
            }
        }

        var path: String? {
            if case let .binaryPath(value) = self {
                value
            } else {
                nil
            }
        }

        var identity: String {
            path == nil ? value : "path:" + value
        }

        var sortKey: String {
            path == nil ? "bundle:" + value : "path:" + value
        }
    }

    /// Typed policy references identify clients, not ownership or an installed
    /// executable. Team-wide and prefix rules cannot name one app.
    private static func clients(in items: [[String: Any]], depth: Int = 0) -> Set<Client> {
        guard depth < 8 else { return [] }
        var clients = Set<Client>()
        for item in items {
            let payload = item["PayloadContent"] as? [String: Any] ?? item
            switch payload["PayloadType"] as? String ?? item["PayloadType"] as? String {
            case "Configuration":
                if let nested = payload["PayloadContent"] as? [[String: Any]] {
                    clients.formUnion(Self.clients(in: nested, depth: depth + 1))
                }
            case "com.apple.TCC.configuration-profile-policy":
                clients.formUnion(privacyClients(in: payload))
            case "com.apple.system-extension-policy":
                clients.formUnion(extensionClients(in: payload))
            case "com.apple.servicemanagement":
                let rules = payload["Rules"] as? [[String: Any]] ?? []
                clients.formUnion(rules.compactMap { rule in
                    guard rule["RuleType"] as? String == "BundleIdentifier" else { return nil }
                    return client(type: "bundleID", value: rule["RuleValue"])
                })
            default: continue
            }
        }
        return clients
    }

    private static func privacyClients(in payload: [String: Any]) -> Set<Client> {
        let services = payload["Services"] as? [String: Any] ?? [:]
        var clients = Set<Client>()
        for (service, value) in services {
            for entry in value as? [[String: Any]] ?? [] {
                if let value = client(type: entry["IdentifierType"], value: entry["Identifier"]) {
                    clients.insert(value)
                }
                let receiver = client(type: entry["AEReceiverIdentifierType"], value: entry["AEReceiverIdentifier"])
                if service == "AppleEvents", let receiver {
                    clients.insert(receiver)
                }
            }
        }
        return clients
    }

    private static func extensionClients(in payload: [String: Any]) -> Set<Client> {
        let keys = ["AllowedSystemExtensions", "RemovableSystemExtensions",
                    "NonRemovableSystemExtensions", "NonRemovableFromUISystemExtensions"]
        return Set(keys.flatMap { key -> [Client] in
            let teams = payload[key] as? [String: [String]] ?? [:]
            return teams.values.flatMap(\.self).compactMap { client(type: "bundleID", value: $0) }
        })
    }

    private static func client(type: Any?, value: Any?) -> Client? {
        guard let type = type as? String, let value = value as? String,
              !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        switch type {
        case "bundleID":
            guard !value.contains("/"), !value.contains("*"),
                  !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
            else { return nil }
            return .bundle(value)
        case "path":
            guard value.hasPrefix("/"), value != "/",
                  !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            else { return nil }
            return .binaryPath(value)
        default: return nil
        }
    }
}
