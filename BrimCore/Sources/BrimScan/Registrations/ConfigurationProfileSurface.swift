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
                for client in Self.bundleClients(in: items).sorted() {
                    records.append(Registration(
                        kind: kind, identifier: identifier, label: label, owningBundleID: client,
                        targetExists: true,
                        evidence: "A configuration profile references \(client). "
                            + "The profile may include other applications or settings.",
                        capability: .refusedByOS,
                        targetPresence: .unknown(
                            "Profile presence does not establish that the referenced app is installed."
                        ),
                        recordIdentity: uuid + ":" + client, namespace: namespace,
                        runtimeState: "Policy reference; removal authority not established"
                    ))
                }
            }
        }
        return RegistrationSnapshot(registrations: records, coverage: .unavailable(
            kind, "Only returned profile references were inspected. "
                + "Device-level policy, other accounts and unrecognized payloads could not be fully checked."
        ), readerVersion: 1)
    }

    private func unreadable() -> RegistrationSnapshot {
        RegistrationSnapshot(registrations: [], coverage: .unavailable(
            kind, "Management profiles could not be read or their listing format was unsupported."
        ))
    }

    /// PPPC explicitly distinguishes a bundle identity from a path-based
    /// client. Do not infer an app from profile names or requirement text.
    private static func bundleClients(in items: [[String: Any]]) -> Set<String> {
        var clients = Set<String>()
        for item in items {
            // profiles versions wrap payloads differently. Only the actual
            // PPPC payload and its typed service clients are accepted.
            let payload = item["PayloadContent"] as? [String: Any] ?? item
            guard (payload["PayloadType"] as? String ?? item["PayloadType"] as? String)
                == "com.apple.TCC.configuration-profile-policy",
                let services = payload["Services"] as? [String: Any] else { continue }
            for value in services.values {
                guard let entries = value as? [[String: Any]] else { continue }
                for entry in entries {
                    guard entry["IdentifierType"] as? String == "bundleID",
                          let identifier = entry["Identifier"] as? String,
                          !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("\0")
                    else { continue }
                    clients.insert(identifier)
                }
            }
        }
        return clients
    }
}
