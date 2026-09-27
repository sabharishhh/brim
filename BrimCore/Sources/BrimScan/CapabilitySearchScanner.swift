import BrimCore
import BrimOps
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// A preflight account of declarations and readable system records.
/// This report never grants ownership or selects a file for removal.
public struct CapabilitySearchScanner: Sendable {
    private let surfaces: [any RegistrationSurface]

    public init(surfaces: [any RegistrationSurface] = [
        AppExtensionSurface(), SystemExtensionSurface(),
        LaunchdRegistrationSurface(), PrivilegedHelperToolSurface(), BundlePluginSurface()
    ]) {
        self.surfaces = surfaces
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func scan(identity: Identity, in root: FileSystemRoot,
                     completeness: ScanCompleteness,
                     evidence: [Evidence] = []) async -> CapabilitySearchReport? {
        guard identity.capabilitySurface != nil || identity.bundleID != nil else { return nil }
        let surface = identity.capabilitySurface
        let bundle = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let ownerPresent = bundle.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let snapshots = await withTaskGroup(of: RegistrationSnapshot.self) { group in
            for source in surfaces {
                group.addTask { await source.snapshot(in: root) }
            }
            var results: [Registration.Kind: RegistrationSnapshot] = [:]
            for await result in group {
                results[result.coverage.kind] = result
            }
            return results
        }

        var checks: [CapabilitySearchReport.Check] = []
        for capability in DeclaredCapability.allCases {
            let coverage: RegistrationCoverage
            let found: [Registration]
            var locations: [String] = []
            switch capability {
            case .privacyGrant:
                coverage = .withheld(.privacyGrant, "Privacy grants cannot be listed for another application.")
                found = []
            case .vpnConfiguration:
                coverage = .withheld(.systemExtension, "VPN settings cannot be listed for another application.")
                found = []
            case .launchServices:
                if root.rootURL.standardizedFileURL.path != "/" {
                    coverage = .withheld(.launchServices, "Launch Services is unavailable in a fixture.")
                    found = []
                } else {
                    let ids = identity.searchBundleIdentifiers
                    do {
                        let urls = try ids.flatMap {
                            try LaunchServicesRegistration.checkedApplicationURLs(forBundleID: $0)
                        }
                        coverage = .available(.launchServices)
                        found = urls.filter { url in
                            guard let bundle else { return false }
                            let path = url.resolvingSymlinksInPath().path
                            return path == bundle || path.hasPrefix(bundle + "/")
                        }.map { url in
                            Registration(kind: .launchServices,
                                         identifier: url.path,
                                         label: url.lastPathComponent,
                                         owningBundleID: identity.bundleID,
                                         programPath: url.path, targetExists: true,
                                         evidence: "Registered with Launch Services.")
                        }
                    } catch {
                        coverage = .unavailable(.launchServices, "Launch Services could not be read.")
                        found = []
                    }
                }
            case .applicationGroups:
                coverage = completeness.isComplete
                    ? .available(.bundlePlugin)
                    : .unavailable(.bundlePlugin, "App group search was incomplete.")
                found = []
                let groups = Set(identity.searchGroupContainers)
                locations = evidence.filter { groups.contains($0.url.lastPathComponent) }
                    .map(\.url.path)
            case .installationRecords:
                let receipts = root.url(for: .receipts)
                switch DirectoryEntries.read(receipts) {
                case .refused:
                    coverage = .unavailable(.installerReceipt, "Installer receipts could not be read.")
                    found = []
                case .absent, .listed:
                    if root.rootURL.standardizedFileURL.path == "/" {
                        if let output = ToolOutput.read("/usr/sbin/pkgutil", ["--pkgs"]) {
                            coverage = .available(.installerReceipt)
                            let ids = Set(identity.searchBundleIdentifiers
                                + [identity.packageIdentifier].compactMap(\.self))
                            found = output.split(separator: "\n").map(String.init)
                                .filter(ids.contains).map { identifier in
                                    Registration(kind: .installerReceipt,
                                                 identifier: identifier, label: identifier,
                                                 owningBundleID: identity.bundleID, targetExists: true,
                                                 evidence: "Installer receipt exists.")
                                }
                        } else {
                            coverage = .unavailable(.installerReceipt, "Installer records could not be read.")
                            found = []
                        }
                    } else {
                        coverage = .available(.installerReceipt)
                        found = []
                    }
                }
                locations = evidence.filter { $0.mechanism == "InstallerReceiptSource" }
                    .map(\.url.path)
            default:
                let kind = capability.registrationKind
                if let snapshot = snapshots[kind] {
                    coverage = snapshot.coverage
                    let ids = Set(identity.searchBundleIdentifiers)
                    let helpers = Set(identity.identitySurface?.helperRequirements.keys.map(\.self) ?? [])
                    let declaredJobs = Set((surface?.declarations ?? [])
                        .filter { $0.capability == .launchdJob && $0.key == "Label" }
                        .map(\.value))
                    found = snapshot.registrations.filter { record in
                        guard !record.isSystemOwned else { return false }
                        if capability == .privilegedHelper {
                            return helpers.contains(record.identifier)
                        }
                        if capability == .launchdJob && declaredJobs.contains(record.identifier) {
                            return true
                        }
                        if ids.contains(record.identifier) {
                            return true
                        }
                        guard let path = record.programPath, let bundle else { return false }
                        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                        return resolved == bundle || resolved.hasPrefix(bundle + "/")
                    }
                } else {
                    coverage = .unavailable(kind, "This record class could not be checked.")
                    found = []
                }
            }
            let declaration = surface?.state(for: capability) ?? .unknown
            let tier = RemovalTier.forCapability(capability, ownerPresent: ownerPresent)
            let followUp: RemovalFollowUp? = switch capability {
            case .systemExtension where !found.isEmpty:
                .vendorUninstaller
            case .vpnConfiguration where declaration == .declared:
                .vpnSettings
            case .privacyGrant where !ownerPresent:
                .restoreAppForPrivacyReset
            default:
                nil
            }
            checks.append(.init(capability: capability, declaration: declaration,
                                coverage: coverage, registrations: found.sorted { $0.id < $1.id },
                                locations: Array(Set(locations)).sorted(), removalTier: tier,
                                followUp: followUp))
        }
        let signatureGaps = surface?.signatureGaps ?? []
        let signature: [RegistrationCoverage] = signatureGaps.isEmpty ? [] : [
            .unavailable(.bundlePlugin,
                         "\(signatureGaps.count) code "
                             + "\(signatureGaps.count == 1 ? "signature" : "signatures") unavailable.")
        ]
        return CapabilitySearchReport(checks: checks, signatureCoverage: signature)
    }
}
