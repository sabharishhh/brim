import Foundation
import BrimCore

/// Lines developer tools append to a shell profile.
///
/// `.zshrc`, `.zprofile`, `.bash_profile` and the rest. Installers add a
/// PATH entry or an init hook and almost none of them take it out again,
/// so a shell keeps sourcing something that no longer exists and every new
/// terminal prints an error.
///
/// **Reported, never edited.** A shell profile is a file somebody wrote by
/// hand, often over years, and silently rewriting it is not something a
/// cleaning tool gets to do. Brim shows the line, the file and the line
/// number, which is everything needed to act, and stops there.
public struct ShellProfileSurface: RegistrationSurface {
    public let kind: Registration.Kind = .shellProfileLine

    public init() {}

    /// The files a login or interactive shell reads. `.profile` is
    /// included because bash falls back to it.
    static let profileNames = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin",
        ".bash_profile", ".bashrc", ".profile", ".login",
    ]

    /// A line only counts when it points at something. A comment, a blank
    /// line, or a shell function is somebody's own configuration and none
    /// of Brim's business; a line naming a path that is gone is the thing
    /// worth showing.
    static let interestingPrefixes = ["source ", ". ", "export PATH", "eval \"$("]

    private func home(in root: FileSystemRoot) -> URL {
        root.url(for: .userLibrary).deletingLastPathComponent()
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        let fm = FileManager.default
        let directory = home(in: root)
        let present = Self.profileNames.filter {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard !present.isEmpty else { return .available(kind) }
        let readable = present.contains {
            fm.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }
        return readable
            ? .available(kind)
            : .unavailable(kind, "Your shell profiles could not be read.",
                           absence: .needsPermission)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        let fm = FileManager.default
        let directory = home(in: root)
        var results: [Registration] = []

        for name in Self.profileNames {
            let file = directory.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, rawLine) in contents.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard Self.isWorthShowing(line) else { continue }
                guard let referenced = Self.pathReferenced(in: line) else { continue }

                let exists = fm.fileExists(atPath: referenced)
                // Only the broken ones. A working line is the person's
                // configuration doing its job, and listing it would bury
                // the one that is wrong.
                guard !exists else { continue }

                results.append(Registration(
                    kind: .shellProfileLine,
                    identifier: "\(name):\(number + 1)",
                    label: line,
                    owningBundleID: nil,
                    programPath: referenced,
                    targetExists: false,
                    recordPath: file.path,
                    evidence: "Line \(number + 1) of ~/\(name) points at \(referenced), which "
                            + "is not there. Every new shell tries this and fails. Brim will "
                            + "not edit your shell configuration, so this one is yours.",
                    isSystemOwned: false,
                    capability: .ok
                ))
            }
        }
        return results
    }

    static func isWorthShowing(_ line: String) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("#") else { return false }
        return interestingPrefixes.contains { line.hasPrefix($0) }
    }

    /// The filesystem path a line refers to, expanded, or nil when it
    /// refers to nothing Brim can check.
    ///
    /// Deliberately narrow. A line full of shell expansion cannot be
    /// resolved without running it, and running somebody's shell
    /// configuration to find out what it does is precisely the thing this
    /// surface exists to avoid.
    static func pathReferenced(in line: String) -> String? {
        var candidate: String?

        if line.hasPrefix("source ") {
            candidate = String(line.dropFirst("source ".count))
        } else if line.hasPrefix(". ") {
            candidate = String(line.dropFirst(2))
        } else if line.hasPrefix("export PATH") {
            // Only a single added component is checkable: PATH=/x/bin:$PATH
            let value = line.drop(while: { $0 != "=" }).dropFirst()
            let parts = value.split(separator: ":")
            candidate = parts.first { $0.hasPrefix("/") || $0.hasPrefix("~") }.map(String.init)
        }

        guard var path = candidate?.trimmingCharacters(in: .whitespaces) else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        // Anything that needs a shell to work out is left alone.
        guard !path.contains("$"), !path.contains("`"), !path.contains("*") else { return nil }
        if path.hasPrefix("~") {
            path = NSHomeDirectory() + path.dropFirst()
        }
        guard path.hasPrefix("/") else { return nil }
        return path
    }
}

/// Keychain entries, named but never touched.
///
/// The product brief keeps secrets out of Brim's remit, and Reset
/// deliberately preserves licence material: an application's keychain
/// entry is frequently the licence somebody paid for, and there is no
/// undo for deleting it.
///
/// Brim cannot enumerate them either, and says so rather than reporting
/// an empty list. `SecItemCopyMatching` returns only what the calling
/// application itself created, so Brim asking would see Brim's own items
/// and nothing else. Reading other applications' entries means prompting
/// for the keychain password once per item, which is not a thing to do
/// during a scan.
public struct KeychainSurface: RegistrationSurface {
    public let kind: Registration.Kind = .keychainItem

    public init() {}

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        .withheld(
            kind,
            "Brim does not read your keychain. macOS only shows an application its own "
            + "entries, and reading anybody else's means a password prompt for each one. "
            + "An application's keychain entry is often the licence you paid for, so if you "
            + "want it gone, Keychain Access is the place."
        )
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] { [] }
}
