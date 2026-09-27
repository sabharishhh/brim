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

    /// `lsregister` is not on `PATH` and has no public replacement; this is
    /// the documented location inside the LaunchServices framework.
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
    ) throws {
        let invoke = runner ?? Self.run
        let status = try invoke(lsregisterPath, ["-u", bundlePath])
        guard status == 0 else {
            throw UnregisterError.failed(path: bundlePath, code: status)
        }
    }

    /// Registers a bundle, used to put back a registration an uninstall
    /// retracted when that uninstall is undone.
    public static func register(
        bundlePath: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) throws {
        let invoke = runner ?? Self.run
        let status = try invoke(lsregisterPath, ["-f", bundlePath])
        guard status == 0 else {
            throw UnregisterError.failed(path: bundlePath, code: status)
        }
    }

    /// Every location Launch Services still associates with a bundle
    /// identifier. Empty means the registration is genuinely gone.
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
        return (result.takeRetainedValue() as? [URL]) ?? []
    }

    /// Runs a fixed tool with fixed arguments. No caller-supplied command
    /// string ever reaches a shell; the step vocabulary forbids it.
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
