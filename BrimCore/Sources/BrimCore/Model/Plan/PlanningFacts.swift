import Foundation

/// A lock that stops a file being removed. Detected here, cleared in
/// `BrimOps`, because the planner must be able to ask and `BrimCore` depends
/// on nothing. `ImmutableFlagAgreementTests` holds the two to one answer.
public enum ArtifactLock: String, Codable, Equatable, Sendable {
    /// `UF_IMMUTABLE`, which is what Finder's "Locked" checkbox sets.
    /// Whoever owns the file can take it off, so Brim can offer to.
    case user
    /// `SF_IMMUTABLE`. Root, and only where System Integrity Protection
    /// allows it at all. Reported, never offered.
    case system

    /// Whether Brim can take this off as the person running the app.
    public var canBeCleared: Bool { self == .user }

    /// Which lock is on a file, if any. `lstat`, so a symbolic link answers for
    /// itself rather than its target.
    public static func on(path: String) -> ArtifactLock? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_flags & UInt32(SF_IMMUTABLE)) != 0 { return .system }
        if (info.st_flags & UInt32(UF_IMMUTABLE)) != 0 { return .user }
        return nil
    }
}

/// Finds the uninstaller a vendor ships, so Brim can point at it. Detection
/// only: Brim reveals it in Finder and never runs it, because whether to
/// trust another developer's executable is the person's decision.
public enum VendorUninstallerDetector {

    public struct Found: Equatable, Sendable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Looks inside a bundle shallowly, on purpose: a deep search matches every
    /// framework containing "uninstall", and a false positive tells someone to
    /// run a stranger's binary.
    public static func insideBundle(
        at bundleURL: URL, fileManager: FileManager = .default
    ) -> Found? {
        let placesVendorsPutThem = [
            bundleURL.appendingPathComponent("Contents/Resources"),
            bundleURL.appendingPathComponent("Contents/MacOS"),
            bundleURL,
        ]

        for directory in placesVendorsPutThem {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in names.sorted() where looksLikeAnUninstaller(name) {
                return Found(
                    path: directory.appendingPathComponent(name).path,
                    reason: "\(bundleURL.lastPathComponent) ships its own uninstaller. Removing "
                          + "the files by hand can leave a licence registered or a system "
                          + "extension loaded. Its uninstaller is shown instead."
                )
            }
        }
        return nil
    }

    /// Whether a file name is an uninstaller, matched on whole words in the
    /// stem: "Adobe Uninstaller.app" is, "UninstallHelperStrings.loctable" is
    /// not.
    public static func looksLikeAnUninstaller(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.contains("uninstall") else { return false }

        let runnable: Set<String> = ["app", "pkg", "tool", "sh", "command", ""]
        let stem = (lowered as NSString).deletingPathExtension
        guard runnable.contains((lowered as NSString).pathExtension) else { return false }

        let words = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { $0 == "uninstall" || $0 == "uninstaller" }
    }
}
