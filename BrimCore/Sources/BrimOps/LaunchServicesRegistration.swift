import BrimCore
import CoreServices
import Foundation

/// Retracting an application's Launch Services registration. Deleting a
/// bundle does not unregister it, which is why a removed app still appears
/// in "Open With". The mirror of `PrivacyGrants`: grants are cleared while
/// the bundle exists, registrations retracted once it is gone, because
/// Launch Services re-registers a bundle it can still see.
public enum LaunchServicesRegistration {
    public enum UnregisterError: Error, LocalizedError, Equatable {
        case failed(path: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case let .failed(path, code):
                "Could not remove the Launch Services registration for \(path) "
                    + "(lsregister exit \(code))."
            }
        }
    }

    /// An undocumented tool at a fixed framework path. Its result never replaces
    /// an independent check of the registration.
    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks"
            + "/LaunchServices.framework/Versions/A/Support/lsregister"

    /// Unregisters one bundle path, and only that path. Never
    /// `lsregister -kill -r`, which rebuilds the database for every app.
    public static func unregister(
        bundlePath: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) async throws {
        try validateBundlePath(bundlePath)
        let status: Int32 = if let runner {
            try runner(lsregisterPath, ["-u", bundlePath])
        } else {
            try await RegistrationCommand.status(lsregisterPath, ["-u", bundlePath])
        }
        guard status == 0 else {
            throw UnregisterError.failed(path: bundlePath, code: status)
        }
    }

    /// Every application bundle inside a folder, found before the folder is
    /// removed so their records can be retracted afterwards; unregistering the
    /// app alone leaves the apps inside it registered.
    public static func nestedApplications(in path: String, limit: Int = 20000) -> [String] {
        var isDirectory: ObjCBool = false
        // Relative paths joined to the path as given: a record is retracted by the
        // spelling it was registered under, and a URL enumerator answers
        // `/private/var` for `/var`.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walk = FileManager.default.enumerator(atPath: path) else { return [] }
        var found: [String] = []
        var seen = 0
        while let relative = walk.nextObject() as? String {
            seen += 1
            if seen > limit {
                break
            }
            if (relative as NSString).pathExtension.lowercased() == "app" {
                found.append((path as NSString).appendingPathComponent(relative))
            }
        }
        return found
    }

    /// Records Launch Services holds inside any of these paths that point at
    /// nothing, including ones an earlier update orphaned, which only the
    /// database knows. A full dump takes seconds, so this runs after a removal.
    public static func staleRecords(inside prefixes: [String], dump: String? = nil) async throws -> [String] {
        let prefixes = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard !prefixes.isEmpty else { return [] }
        let listing: String = if let dump {
            dump
        } else {
            try await RegistrationCommand.read(lsregisterPath, ["-dump"])
        }
        return Set(recordedPaths(in: listing).filter { path in
            prefixes.contains(where: { path.hasPrefix($0) }) && PathObservation.observe(path).isAbsent
        }).sorted()
    }

    /// Whether the database has a record for exactly this path. Asking by bundle
    /// identifier is a different question: it leaves out records whose bundle
    /// has gone.
    public static func isRecorded(path: String, dump: String? = nil) async throws -> Bool {
        let listing: String = if let dump {
            dump
        } else {
            try await RegistrationCommand.read(lsregisterPath, ["-dump"])
        }
        return recordedPaths(in: listing).contains(path)
    }

    private static func recordedPaths(in listing: String) -> [String] {
        listing.split(separator: "\n").filter { $0.hasPrefix("path:") }.map { line in
            let path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            guard let marker = path.range(of: " (0x", options: .backwards) else { return path }
            return String(path[..<marker.lowerBound])
        }
    }

    public static func register(
        bundlePath: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) async throws {
        try validateBundlePath(bundlePath)
        let status: Int32 = if let runner {
            try runner(lsregisterPath, ["-f", bundlePath])
        } else {
            try await RegistrationCommand.status(lsregisterPath, ["-f", bundlePath])
        }
        guard status == 0 else {
            throw UnregisterError.failed(path: bundlePath, code: status)
        }
    }

    /// A lookup that discards errors. Use the checked lookup for ownership
    /// decisions and verification.
    public static func registeredApplicationURLs(forBundleID bundleID: String) -> [URL] {
        (try? checkedApplicationURLs(forBundleID: bundleID)) ?? []
    }

    /// Keeps a failed query as a failure, so a review never shows it as an empty
    /// registration.
    public static func checkedApplicationURLs(forBundleID bundleID: String) throws -> [URL] {
        var error: Unmanaged<CFError>?
        guard let result = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error) else {
            if let error {
                let failure = error.takeRetainedValue()
                if CFErrorGetCode(failure) == kLSApplicationNotFoundErr {
                    return []
                }
                throw failure
            }
            throw NSError(domain: "LaunchServices", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Launch Services did not answer."])
        }
        guard let urls = result.takeRetainedValue() as? [URL] else {
            throw NSError(domain: "LaunchServices", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Launch Services returned an unreadable result."])
        }
        return urls
    }

    public static func unregisterBounded(bundlePath: String) async throws {
        try validateBundlePath(bundlePath)
        let status = try await RegistrationCommand.status(lsregisterPath, ["-u", bundlePath])
        guard status == 0 else { throw UnregisterError.failed(path: bundlePath, code: status) }
    }

    public static func registerBounded(bundlePath: String) async throws {
        try validateBundlePath(bundlePath)
        let status = try await RegistrationCommand.status(lsregisterPath, ["-f", bundlePath])
        guard status == 0 else { throw UnregisterError.failed(path: bundlePath, code: status) }
    }

    private static func validateBundlePath(_ path: String) throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path != "/",
              !path.contains("\0")
        else {
            throw UnregisterError.failed(path: path, code: EINVAL)
        }
    }
}
