import BrimCore
import CoreServices
import Foundation

/// Retracting an application's Launch Services registration.
///
/// **Deleting a bundle does not unregister it.** Launch Services keeps the
/// record — bundle identifier, document types, URL schemes, the path it was
/// last seen at — until something explicitly retracts it or the database is
/// rebuilt. That stale record is why a removed app still appears in "Open
/// With", still claims its file types, and still answers when something
/// resolves its bundle identifier.
///
/// **Order is the mirror image of `PrivacyGrants`.** A privacy reset must
/// run while the bundle is present, because `tccutil` resolves the identifier
/// *through* Launch Services. Unregistering must run once the bundle is gone,
/// because Launch Services re-registers a bundle it can still see. So the two
/// bracket the removal: grants first, registration last.
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

    /// An undocumented maintenance tool at a fixed framework location.
    /// Its result never replaces an independent registration observation.
    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks"
            + "/LaunchServices.framework/Versions/A/Support/lsregister"

    /// Unregisters one bundle path, and only that path.
    ///
    /// Deliberately *not* `lsregister -kill -r`: rebuilding the database
    /// touches every application on the machine and can take minutes. That is
    /// a repair the user asks for, never a side effect of one uninstall.
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

    /// Registers a bundle, used to put back a registration an uninstall
    /// retracted when that uninstall is undone.
    /// Every application bundle inside a folder, found before the folder
    /// is removed so their records can be retracted afterwards.
    ///
    /// Unregistering the application left the ones inside it registered:
    /// after Muse went, Launch Services still listed Sparkle's `Updater.app`
    /// inside `Muse.app` and two more copies Sparkle keeps in its cache
    /// folder, all pointing at nothing.
    public static func nestedApplications(in path: String, limit: Int = 20000) -> [String] {
        var isDirectory: ObjCBool = false
        // Relative paths, joined to the path as given: a URL enumerator
        // answers `/private/var` for `/var`, and a record is retracted by
        // the spelling it was registered under.
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

    /// Records Launch Services holds inside any of these paths that point
    /// at nothing.
    ///
    /// Finding the applications inside a bundle before it goes misses the
    /// ones an update already removed: Teams' embedded browser had moved to
    /// a new version folder, and three helpers in the old one stayed
    /// registered through its uninstall. Only the database knows those. A
    /// full dump takes seconds, so this runs after a removal, not during.
    public static func staleRecords(inside prefixes: [String], dump: String? = nil) async throws -> [String] {
        let prefixes = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard !prefixes.isEmpty else { return [] }
        let listing: String = if let dump {
            dump
        } else {
            try await RegistrationCommand.read(lsregisterPath, ["-dump"])
        }
        var found = Set<String>()
        for line in listing.split(separator: "\n") where line.hasPrefix("path:") {
            var path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            if let marker = path.range(of: " (0x", options: .backwards) {
                path = String(path[..<marker.lowerBound])
            }
            guard prefixes.contains(where: { path.hasPrefix($0) }),
                  PathObservation.observe(path).isAbsent else { continue }
            found.insert(path)
        }
        return found.sorted()
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

    /// Compatibility lookup that discards errors. Use the checked lookup
    /// for ownership decisions and absence verification.
    ///
    /// Read-only, and the only way to *check* this surface: the Launch
    /// Services database has no supported reader, and `lsregister -dump`
    /// takes seconds and returns megabytes of text.
    public static func registeredApplicationURLs(forBundleID bundleID: String) -> [URL] {
        (try? checkedApplicationURLs(forBundleID: bundleID)) ?? []
    }

    /// Unlike the compatibility reader, this preserves a failed query so a
    /// review cannot present it as an empty registration.
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
