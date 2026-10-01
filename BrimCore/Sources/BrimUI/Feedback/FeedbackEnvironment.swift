import Foundation

public struct FeedbackEnvironment: Codable, Equatable, Sendable {
    public let appVersion: String
    public let build: String
    public let operatingSystem: String
    public let architecture: String

    public init(appVersion: String, build: String, operatingSystem: String, architecture: String) {
        self.appVersion = appVersion
        self.build = build
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public var text: String {
        let buildLabel = build.isEmpty ? "build number unavailable" : build
        return "\(appLabel) (\(buildLabel))\nmacOS \(operatingSystem)\n\(architecture)"
    }

    public var appLabel: String {
        appVersion.isEmpty ? "Brim version unavailable" : "Brim \(appVersion)"
    }

    public static var current: Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
            let architecture = "Apple silicon"
        #else
            let architecture = "Intel"
        #endif
        return Self(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            operatingSystem: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture
        )
    }
}
