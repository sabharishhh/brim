import Foundation
import BrimCore

/// Lines developer tools append to a shell profile (`.zshrc`, `.zprofile`,
/// `.bash_profile` and the rest) that point at something no longer there,
/// so every new terminal prints an error. Reported, never edited: Brim shows
/// the line, the file and the line number.
public struct ShellProfileSurface: RegistrationSurface {
    public let kind: Registration.Kind = .shellProfileLine

    public init() {}

    /// The files a login or interactive shell reads. `.profile` is
    /// included because bash falls back to it.
    static let profileNames = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin",
        ".bash_profile", ".bashrc", ".profile", ".login",
    ]

    /// A line counts only when it points at something; comments, blank lines
    /// and functions are the person's own configuration.
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
                // Only broken lines: listing working ones would bury the wrong one.
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
                            + "is not there. Every new shell tries this and fails.",
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

    /// The path a line refers to, expanded, or nil when it is nothing Brim can
    /// check. Narrow on purpose: resolving shell expansion would mean running
    /// the person's configuration.
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

/// Keychain entries, named but never touched: an app's entry is often a
/// licence someone paid for. Brim cannot list them either, and says so:
/// `SecItemCopyMatching` returns only the caller's own items, and reading
/// other apps' entries prompts for each one.
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
