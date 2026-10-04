import AppKit
import BrimCore
import Foundation
import Security

extension UpdateInstaller {
    // MARK: - Checking

    /// Nil when the candidate may replace the installed application. An
    /// outcome when it is not needed, and an error when it is refused.
    static func verify(_ candidate: URL, replacing installed: URL) throws -> UpdateOutcome? {
        guard identifier(of: candidate)?.lowercased() == identifier(of: installed)?.lowercased() else {
            throw Failure.differentApplication
        }
        try satisfiesDesignatedRequirement(candidate, of: installed)
        guard isNewer(candidate, than: installed) else { return .alreadyCurrent }
        let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        let minimum = info?["LSMinimumSystemVersion"] as? String
        if let minimum, !UpdatePlatformCheck.canRun(minimum: minimum) {
            throw Failure.needsNewerMacOS(minimum)
        }
        let architectures = Bundle(url: candidate)?.executableArchitectures?.map(\.intValue) ?? []
        #if arch(arm64)
            let runnable = architectures.contains(NSBundleExecutableArchitectureARM64)
                || architectures.contains(NSBundleExecutableArchitectureX86_64)
        #else
            let runnable = architectures.contains(NSBundleExecutableArchitectureX86_64)
        #endif
        guard architectures.isEmpty || runnable else { throw Failure.wrongArchitecture }
        guard passesGatekeeper(candidate) else { throw Failure.gatekeeper }
        return nil
    }

    static func satisfiesDesignatedRequirement(_ candidate: URL, of installed: URL) throws {
        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode,
              teamIdentifier(of: installed) != nil,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement
        else { throw Failure.installedIsUnsigned }
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidityWithErrors(
                  candidateCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                  requirement, nil
              ) == errSecSuccess
        else { throw Failure.notSignedBySameDeveloper }
    }

    /// `spctl` is Gatekeeper's own assessment, notarization included; the
    /// API behind it is not available to Swift.
    static func passesGatekeeper(_ candidate: URL, type: String = "execute") -> Bool {
        run("/usr/sbin/spctl", ["--assess", "--type", type, candidate.path])
    }

    static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
              == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func isNewer(_ candidate: URL, than installed: URL) -> Bool {
        let new = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        let old = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let newVersion = new?[key] as? String, let oldVersion = old?[key] as? String else { continue }
            switch VersionOrder.compare(newVersion, oldVersion) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: continue
            }
        }
        return false
    }

    /// An installer package is opened only when its signature names the
    /// application's own developer and Gatekeeper accepts it.
    static func checkPackage(_ package: URL, against installed: URL) throws {
        guard let team = teamIdentifier(of: installed),
              let output = runOutput("/usr/sbin/pkgutil", ["--check-signature", package.path]),
              output.contains("Developer ID Installer:"), output.contains("(\(team))")
        else { throw Failure.packageNotSignedBySameDeveloper }
        guard passesGatekeeper(package, type: "install") else { throw Failure.gatekeeper }
    }
}

/// This Mac's version, compared the way feeds write it.
enum UpdatePlatformCheck {
    static func canRun(minimum: String) -> Bool {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return VersionOrder.compare(minimum, current) != .orderedDescending
    }
}
