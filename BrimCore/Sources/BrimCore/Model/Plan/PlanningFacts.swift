import Foundation

/// A lock that stops a file being removed.
///
/// Detection lives here and clearing lives in `BrimOps`, because
/// `BrimCore` depends on nothing and the planner has to be able to ask the
/// question. `ImmutableFlagAgreementTests` holds the two halves to the
/// same answer.
public enum ArtifactLock: String, Codable, Equatable, Sendable {
    /// `UF_IMMUTABLE`, which is what Finder's "Locked" checkbox sets.
    /// Whoever owns the file can take it off, so Brim can offer to.
    case user
    /// `SF_IMMUTABLE`. Root, and only where System Integrity Protection
    /// allows it at all. Reported, never offered.
    case system

    /// Whether Brim can take this off as the person running the app.
    public var canBeCleared: Bool { self == .user }

    /// Which lock is on a file, if any.
    ///
    /// `lstat`, so a symlink answers about itself. `attributesOfItem`
    /// follows the link and would report the target's flags, which is the
    /// same trap that made symlinks count as their target's size.
    public static func on(path: String) -> ArtifactLock? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_flags & UInt32(SF_IMMUTABLE)) != 0 { return .system }
        if (info.st_flags & UInt32(UF_IMMUTABLE)) != 0 { return .user }
        return nil
    }
}

/// Finding the uninstaller a vendor ships, so Brim can point at it rather
/// than guess.
///
/// Detection only. Revealing it in Finder is `BrimOps.VendorUninstaller`,
/// and running it is nobody's job: the whole value of the step is that a
/// person decides whether to trust somebody else's executable.
public enum VendorUninstallerDetector {

    public struct Found: Equatable, Sendable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Looks inside an application bundle, shallowly and on purpose.
    ///
    /// A deep search matches every framework that ships a string with
    /// "uninstall" in it, and a false positive here tells somebody to run
    /// a stranger's binary.
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
                          + "extension loaded, so the vendor's uninstaller is shown instead."
                )
            }
        }
        return nil
    }

    /// Whether a file name is an uninstaller rather than something that
    /// merely contains the word.
    ///
    /// Matched on whole words in the stem, so "Uninstaller.app" and
    /// "Adobe Uninstaller.app" qualify and "UninstallHelperStrings.loctable"
    /// does not.
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
