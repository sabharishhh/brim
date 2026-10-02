import BrimCore
import BrimOps
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// A preflight account of declarations and readable system records.
/// This report never grants ownership or selects a file for removal.
public struct CapabilitySearchScanner: Sendable {
    private let surfaces: [any RegistrationSurface]

    public init(surfaces: [any RegistrationSurface] = [
        ConfigurationProfileSurface(), FirewallSurface(), BackgroundItemSurface(),
        AppExtensionSurface(), SystemExtensionSurface(),
        LaunchdRegistrationSurface(includeSystemJobs: false), PrivilegedHelperToolSurface(), BundlePluginSurface()
    ]) {
        self.surfaces = surfaces
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func scan(
        identity: Identity,
        in root: FileSystemRoot,
        completeness: ScanCompleteness,
        evidence: [Evidence] = [],
        expectedRegistrations: [Registration] = [],
        recoveryLocations: [URL] = []
    ) async -> CapabilitySearchReport? {
        guard identity.capabilitySurface != nil || identity.bundleID != nil else { return nil }
        let surface = identity.capabilitySurface
        let bundle = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let ownerPresent = PathObservation.observe(bundle).isPresent
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

        let embeddedJobs = EmbeddedLaunchdDeclarations.read(identity: identity)
        var checks: [CapabilitySearchReport.Check] = []
        for capability in DeclaredCapability.allCases {
            var coverage: RegistrationCoverage
            var found: [Registration]
            var locations: [String] = []
            switch capability {
            case .fileProvider:
                coverage = .withheld(.bundlePlugin, "Cloud data must be managed with its owning application.")
                found = []
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
                    let ids = Array(Set(identity.searchBundleIdentifiers
                            + expectedRegistrations.filter { $0.kind == .launchServices }
                            .map(\.identifier).filter { !$0.hasPrefix("/") }))
                    do {
                        let urls = try ids.flatMap { identifier in
                            try LaunchServicesRegistration.checkedApplicationURLs(forBundleID: identifier)
                                .map { (identifier: identifier, url: $0) }
                        }
                        coverage = .available(.launchServices)
                        found = urls.filter { entry in
                            let url = entry.url
                            guard let bundle else { return false }
                            let path = url.resolvingSymlinksInPath().path
                            return path == bundle || path.hasPrefix(bundle + "/") || recoveryLocations.contains {
                                let recovery = $0.resolvingSymlinksInPath().path
                                return path == recovery || path.hasPrefix(recovery + "/")
                            }
                        }.map { entry in
                            let url = entry.url
                            return Registration(kind: .launchServices,
                                                identifier: entry.identifier,
                                                label: url.lastPathComponent,
                                                owningBundleID: entry.identifier,
                                                programPath: url.path, targetExists: true,
                                                evidence: "Registered with Launch Services.",
                                                targetPresence: PathObservation.observe(url.path))
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
                locations = evidence.filter { $0.mechanism == "InstallerReceiptSource" }.map(\.url.path)
                let ids = Set(identity.searchBundleIdentifiers
                    + [identity.packageIdentifier].compactMap(\.self)
                    + expectedRegistrations.filter { $0.kind == .installerReceipt }.map(\.identifier)
                    + locations.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
                let directories = [root.url(for: .systemReceipts), root.url(for: .receipts)]
                let listings = directories.map { DirectoryEntries.read($0) }
                if listings.contains(where: \.isRefused) {
                    coverage = .unavailable(.installerReceipt, "Installer receipts could not be read.")
                    found = []
                } else if root.rootURL.standardizedFileURL.path == "/" {
                    if let output = ToolOutput.read("/usr/sbin/pkgutil", ["--pkgs"]) {
                        coverage = .available(.installerReceipt)
                        found = output.split(separator: "\n").map(String.init).filter(ids.contains).map { identifier in
                            Registration(kind: .installerReceipt, identifier: identifier, label: identifier,
                                         owningBundleID: identity.bundleID, targetExists: true,
                                         evidence: "Installer receipt exists.")
                        }
                    } else {
                        coverage = .unavailable(.installerReceipt, "Installer records could not be read.")
                        found = []
                    }
                } else {
                    coverage = .available(.installerReceipt)
                    found = ids.sorted().filter { identifier in
                        directories.contains { directory in
                            PathObservation.observe(directory.appendingPathComponent(identifier + ".plist").path)
                                .isPresent
                                || PathObservation.observe(directory.appendingPathComponent(identifier + ".bom").path)
                                .isPresent
                        }
                    }.map { identifier in
                        Registration(kind: .installerReceipt, identifier: identifier, label: identifier,
                                     owningBundleID: identity.bundleID, targetExists: true,
                                     evidence: "Installer receipt exists.")
                    }
                }
            default:
                let kind = capability.registrationKind
                if let snapshot = snapshots[kind] {
                    coverage = snapshot.coverage
                    let prior = expectedRegistrations.filter { $0.kind == kind }
                    let ids = Set(identity.searchBundleIdentifiers)
                    let helpers = Set(identity.identitySurface?.helperRequirements.keys.map(\.self) ?? [])
                    let declaredJobs = Set((surface?.declarations ?? [])
                        .filter { $0.capability == .launchdJob && $0.key == "Label" }
                        .map(\.value))
                    found = snapshot.registrations.filter { record in
                        guard !record.isSystemOwned else { return false }
                        if prior.contains(where: { $0.id == record.id }) {
                            return true
                        }
                        if capability == .privilegedHelper {
                            return helpers.contains(record.identifier)
                        }
                        if capability == .launchdJob && declaredJobs.contains(record.identifier) {
                            return true
                        }
                        if ids.contains(record.identifier) || record.owningBundleID.map(ids.contains) == true {
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
            if capability == .launchdJob {
                let known = Set(found.map(\.id))
                found += embeddedJobs.registrations.filter { !known.contains($0.id) }
                if !embeddedJobs.coverage.available {
                    coverage = .unavailable(.launchdJob, "An embedded background job could not be checked.")
                }
            }
            let declaration = surface?.state(for: capability) ?? .unknown
            let tier: RemovalTier = capability == .launchdJob && !embeddedJobs.registrations.isEmpty
                ? .detectableOnly : RemovalTier.forCapability(capability, ownerPresent: ownerPresent)
            let followUp: RemovalFollowUp? = switch capability {
            case .appExtension where !found.isEmpty:
                .systemExtensionsSettings
            case .firewallEntry where !found.isEmpty:
                .firewallSettings
            case .configurationProfile where !found.isEmpty:
                .deviceManagementSettings
            case .fileProvider where declaration == .declared:
                .fileProviderOwner
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
                                followUp: followUp,
                                observedAt: snapshots[capability.registrationKind]?.observedAt ?? Date(),
                                readerVersion: snapshots[capability.registrationKind]?.readerVersion ?? 2))
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
