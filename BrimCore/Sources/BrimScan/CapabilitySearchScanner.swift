import BrimCore
import BrimOps
import Darwin
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
        recoveryLocations: [URL] = [],
        removalLocations: [String] = []
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
                let check = Self.launchServicesCheck(
                    identity: identity, in: root, removalLocations: removalLocations,
                    expectedRegistrations: expectedRegistrations, recoveryLocations: recoveryLocations,
                    discoverApplications: !removalLocations.isEmpty
                )
                coverage = check.coverage
                found = check.registrations
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

public extension CapabilitySearchScanner {
    /// Reads only the reviewed paths. Other installations with the same
    /// identifier keep their own registrations.
    static func launchServicesCheck(
        identity: Identity, in root: FileSystemRoot,
        removalLocations: [String] = [], expectedRegistrations: [Registration] = [],
        recoveryLocations: [URL] = [], discoverApplications: Bool = false,
        reviewedCoverage: RegistrationCoverage? = nil,
        lookup: (String) throws -> [URL] = LaunchServicesRegistration.checkedApplicationURLs
    ) -> CapabilitySearchReport.Check {
        let observedAt = Date()
        guard root.rootURL.standardizedFileURL.path == "/" else {
            return .init(capability: .launchServices, declaration: .unknown,
                         coverage: .withheld(.launchServices, "Launch Services is unavailable in a fixture."),
                         observedAt: observedAt, readerVersion: 2)
        }
        let discovered = discoverApplications ? applicationsInside(removalLocations) : (records: [], complete: true)
        let reviewed = expectedRegistrations.filter { $0.kind == .launchServices }
        let exactPaths = Set((reviewed + discovered.records).compactMap(\.programPath))
        let identifiers = Set(identity.searchBundleIdentifiers
            + (reviewed + discovered.records).map(\.identifier).filter { !$0.hasPrefix("/") })
        let prefixes = (removalLocations + recoveryLocations.map(\.path) + [identity.bundlePath].compactMap(\.self))
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        do {
            let records = try identifiers.sorted().flatMap { identifier in
                try lookup(identifier).filter { url in
                    let path = url.standardizedFileURL.path
                    return exactPaths.contains(path) || prefixes.contains { prefix in
                        path == prefix || path.hasPrefix(prefix + "/")
                    }
                }.map { url in
                    Registration(kind: .launchServices, identifier: identifier, label: url.lastPathComponent,
                                 owningBundleID: identifier, programPath: url.path, targetExists: true,
                                 evidence: "Registered with Launch Services.",
                                 targetPresence: PathObservation.observe(url.path))
                }
            }
            let knownIDs = reviewed.allSatisfy { !$0.identifier.hasPrefix("/") }
            return .init(capability: .launchServices, declaration: .unknown,
                         coverage: discovered.complete && knownIDs && reviewedCoverage?.available != false
                             ? .available(.launchServices)
                             : .unavailable(.launchServices, "An application registration could not be checked."),
                         registrations: records.sorted { $0.id < $1.id },
                         observedAt: observedAt, readerVersion: 2)
        } catch {
            return .init(capability: .launchServices, declaration: .unknown,
                         coverage: .unavailable(.launchServices, "Launch Services could not be read."),
                         observedAt: observedAt, readerVersion: 2)
        }
    }

    /// The removed cache/support folder can contain complete helper apps.
    /// Bound discovery and never descend through links to surviving software.
    private static func applicationsInside(_ paths: [String]) -> (records: [Registration], complete: Bool) {
        let budget = ScanBudget(total: 4)
        var remaining = 20000
        var complete = true
        var applications = Set<String>()
        for path in Set(paths).sorted() {
            guard remaining > 0, !budget.hasRunOut else { complete = false; break }
            let root = URL(fileURLWithPath: path)
            // An alias to a directory does not extend the approved scope to
            // the bundle on the other side of that link.
            guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
                complete = false
                continue
            }
            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            } catch {
                if !PathObservation.observe(path).isAbsent {
                    complete = false
                }
                continue
            }
            if root.pathExtension.lowercased() == "app" {
                applications.insert(path)
            }
            let walked = applicationPaths(in: root, maximum: remaining, budget: budget)
            remaining -= walked.entries
            complete = complete && walked.complete
            applications.formUnion(walked.paths)
        }
        let records = applications.sorted().compactMap { path -> Registration? in
            guard let identifier = applicationIdentifier(at: path) else {
                complete = false
                return nil
            }
            return Registration(kind: .launchServices, identifier: identifier,
                                label: URL(fileURLWithPath: path).lastPathComponent,
                                owningBundleID: identifier, programPath: path, targetExists: true,
                                evidence: "Application inside a selected removal location.")
        }
        return (records, complete)
    }

    private struct ApplicationWalk {
        var paths = Set<String>()
        var complete = true
        var entries = 0
    }

    private static func applicationPaths(in root: URL, maximum: Int, budget: ScanBudget) -> ApplicationWalk {
        var result = ApplicationWalk()
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, _ in result.complete = false; return true }
        ) else {
            result.complete = false
            return result
        }
        while let child = walk.nextObject() as? URL {
            guard result.entries < maximum, !budget.hasRunOut else {
                result.complete = false
                break
            }
            result.entries += 1
            guard let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                result.complete = false
                walk.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true {
                walk.skipDescendants()
                continue
            }
            if child.pathExtension.lowercased() == "app" {
                result.paths.insert(child.path)
            }
        }
        return result
    }

    /// Only a bounded regular metadata file can name a reviewed application.
    static func applicationIdentifier(at path: String) -> String? {
        let bundle = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard bundle >= 0 else { return nil }
        defer { close(bundle) }
        let contents = openat(bundle, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { return nil }
        defer { close(contents) }
        let descriptor = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else { return nil }
        let size = Int(info.st_size)
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, size) }
        guard count == size,
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = metadata["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }
}
