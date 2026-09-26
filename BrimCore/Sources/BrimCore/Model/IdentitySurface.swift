import Foundation

/// Names retain their meaning: a URL scheme is never treated as a file name.
public struct IdentitySurface: Codable, Equatable, Hashable, Sendable {
    public struct Component: Codable, Equatable, Hashable, Sendable {
        public let path: String
        public let bundleIdentifier: String?
        public let signingIdentifier: String?
        public let name: String
        public let bundleName: String?
        public let displayName: String?
        public let executableName: String?
        public let teamIdentifier: String?
        public let groups: [String]
        public let urlSchemes: [String]
        public let exportedTypes: [String]

        public init(path: String, bundleIdentifier: String?, name: String, bundleName: String?,
                    signingIdentifier: String? = nil, displayName: String? = nil,
                    executableName: String? = nil,
                    teamIdentifier: String?, groups: [String], urlSchemes: [String], exportedTypes: [String])
        {
            self.path = path
            self.bundleIdentifier = bundleIdentifier
            self.signingIdentifier = signingIdentifier
            self.name = name
            self.bundleName = bundleName
            self.displayName = displayName
            self.executableName = executableName
            self.teamIdentifier = teamIdentifier
            self.groups = groups
            self.urlSchemes = urlSchemes
            self.exportedTypes = exportedTypes
        }
    }

    public let bundlePath: String
    public let components: [Component]
    public let helperRequirements: [String: String]

    public init(bundlePath: String, components: [Component], helperRequirements: [String: String] = [:]) {
        self.bundlePath = bundlePath
        self.components = components
        self.helperRequirements = helperRequirements
    }

    public var bundleIdentifiers: [String] {
        Self.unique(components.flatMap { [$0.bundleIdentifier, $0.signingIdentifier].compactMap(\.self) })
    }

    public var searchableBundleIdentifiers: [String] {
        let ownerTeam = components.first?.teamIdentifier
        return Self.unique(components.filter { component in
            component.path == bundlePath || ownerTeam == nil
                || component.teamIdentifier == nil || component.teamIdentifier == ownerTeam
        }.flatMap { [$0.bundleIdentifier, $0.signingIdentifier].compactMap(\.self) })
    }

    public var names: [String] {
        Self.unique(components.flatMap {
            [$0.name, $0.bundleName, $0.displayName, $0.executableName].compactMap(\.self)
        })
    }

    public var groups: [String] {
        Self.unique(components.flatMap(\.groups))
    }

    public var urlSchemes: [String] {
        Self.unique(components.flatMap(\.urlSchemes))
    }

    public var exportedTypes: [String] {
        Self.unique(components.flatMap(\.exportedTypes))
    }

    public static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

public enum DeclaredCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case systemExtension, vpnConfiguration, privilegedHelper, launchdJob, appExtension
    case privacyGrant, launchServices, applicationGroups, bundlePlugin, installationRecords

    public var title: String {
        switch self {
        case .systemExtension: "System extensions"
        case .vpnConfiguration: "VPN settings"
        case .privilegedHelper: "Privileged helpers"
        case .launchdJob: "Background jobs"
        case .appExtension: "App extensions"
        case .privacyGrant: "Privacy permissions"
        case .launchServices: "File and URL associations"
        case .applicationGroups: "App groups"
        case .bundlePlugin: "Plug-ins"
        case .installationRecords: "Installation records"
        }
    }

    public var registrationKind: Registration.Kind {
        switch self {
        case .systemExtension, .vpnConfiguration: .systemExtension
        case .privilegedHelper: .privilegedHelper
        case .launchdJob: .launchdJob
        case .appExtension: .appExtension
        case .privacyGrant: .privacyGrant
        case .launchServices: .launchServices
        case .applicationGroups: .bundlePlugin
        case .bundlePlugin: .bundlePlugin
        case .installationRecords: .installerReceipt
        }
    }

    public var needsEntitlements: Bool {
        switch self {
        case .systemExtension, .vpnConfiguration, .privacyGrant, .applicationGroups: true
        default: false
        }
    }
}

public struct CapabilitySurface: Codable, Equatable, Hashable, Sendable {
    public enum DeclarationState: String, Codable, Equatable, Hashable, Sendable {
        case declared, notDeclared, unknown
    }

    public struct Declaration: Codable, Equatable, Hashable, Sendable {
        public let capability: DeclaredCapability
        public let key: String
        public let value: String
        public let path: String

        public init(_ capability: DeclaredCapability, key: String, value: String, path: String) {
            self.capability = capability
            self.key = key
            self.value = value
            self.path = path
        }
    }

    public struct Gap: Codable, Equatable, Hashable, Sendable {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) {
            self.path = path; self.reason = reason
        }
    }

    public let declarations: [Declaration]
    public let signatureGaps: [Gap]
    public let unreadable: [String]
    public let timedOut: [String]

    public init(declarations: [Declaration], signatureGaps: [Gap] = [],
                unreadable: [String] = [], timedOut: [String] = [])
    {
        self.declarations = declarations
        self.signatureGaps = signatureGaps
        self.unreadable = unreadable
        self.timedOut = timedOut
    }

    public var completeness: ScanCompleteness {
        ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
    }

    public func state(for capability: DeclaredCapability) -> DeclarationState {
        if declarations.contains(where: { $0.capability == capability }) {
            return .declared
        }
        if !completeness.isComplete || (capability.needsEntitlements && !signatureGaps.isEmpty) {
            return .unknown
        }
        return .notDeclared
    }
}

/// Read status and declaration status are independent. Neither implies the other.
public struct CapabilitySearchReport: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable, Identifiable {
        public let capability: DeclaredCapability
        public let declaration: CapabilitySurface.DeclarationState
        public let coverage: RegistrationCoverage
        public let registrations: [Registration]
        public let locations: [String]
        public var id: String {
            capability.rawValue
        }

        public init(capability: DeclaredCapability, declaration: CapabilitySurface.DeclarationState,
                    coverage: RegistrationCoverage, registrations: [Registration] = [],
                    locations: [String] = [])
        {
            self.capability = capability
            self.declaration = declaration
            self.coverage = coverage
            self.registrations = registrations
            self.locations = locations
        }
    }

    public let checks: [Check]
    public let signatureCoverage: [RegistrationCoverage]

    public init(checks: [Check], signatureCoverage: [RegistrationCoverage]) {
        self.checks = checks
        self.signatureCoverage = signatureCoverage
    }
}
