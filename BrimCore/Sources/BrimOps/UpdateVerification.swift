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
        run("/usr/sbin/spctl", ["--assess", "--type", type, candidate.path], timeout: 120)
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
              let check = BoundedTool.run("/usr/sbin/pkgutil", ["--check-signature", package.path], timeout: 60),
              check.status == 0, installerTeam(fromSignatureCheck: check.output) == team
        else { throw Failure.packageNotSignedBySameDeveloper }
        guard passesGatekeeper(package, type: "install") else { throw Failure.gatekeeper }
    }

    /// The team of the certificate that signed a package, from the first
    /// entry of `pkgutil --check-signature`'s certificate chain, and from
    /// nowhere else.
    ///
    /// The check used to look for "Developer ID Installer:" and "(TEAM)"
    /// anywhere in the output and ignored the exit status, but the output
    /// begins with the file name, which the download server chooses. A
    /// package signed by anybody's Developer ID and named `Update (TEAM).pkg`
    /// passed as the app's own developer's.
    static func installerTeam(fromSignatureCheck output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let chain = lines.firstIndex(of: "Certificate Chain:"), chain + 1 < lines.count else { return nil }
        let leaf = lines[chain + 1]
        let prefix = "1. Developer ID Installer: "
        guard leaf.hasPrefix(prefix), leaf.hasSuffix(")"), let open = leaf.lastIndex(of: "(") else { return nil }
        let team = leaf[leaf.index(after: open) ..< leaf.index(before: leaf.endIndex)]
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return String(team)
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
