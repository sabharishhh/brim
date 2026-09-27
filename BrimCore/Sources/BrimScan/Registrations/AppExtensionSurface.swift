import BrimCore
import Foundation

/// App extensions, as PluginKit knows them.
///
/// Finder Sync, Share, Widgets, Quick Look previews, Spotlight importers,
/// Action extensions, notification services. They live inside the owning
/// bundle, so deleting the application takes the files, but PluginKit's
/// own registration can outlive them: the extension keeps appearing in
/// System Settings, in a Share sheet, or in the Finder's toolbar with
/// nothing behind it.
///
/// `pluginkit -m -v` prints one line per extension. There is no API for
/// this, so the tool's output is the only way in.
public struct AppExtensionSurface: RegistrationSurface {
    public let kind: Registration.Kind = .appExtension

    private let read: @Sendable () -> String?

    public init(
        read: @escaping @Sendable () -> String? = {
            ToolOutput.read("/usr/bin/pluginkit", ["-m", "-v"])
        }
    ) {
        self.read = read
    }

    public func coverage(in _: FileSystemRoot) async -> RegistrationCoverage {
        read() == nil
            ? .unavailable(kind, "pluginkit did not answer, so app extensions were not read.")
            : .available(kind)
    }

    public func snapshot(in _: FileSystemRoot) async -> RegistrationSnapshot {
        guard let output = read() else {
            return RegistrationSnapshot(registrations: [],
                                        coverage: .unavailable(kind, "App extensions could not be read."))
        }
        return RegistrationSnapshot(registrations: Self.registrations(from: output), coverage: .available(kind))
    }

    public func registrations(in _: FileSystemRoot) async -> [Registration] {
        guard let output = read() else { return [] }
        return Self.registrations(from: output)
    }

    private static func registrations(from output: String) -> [Registration] {
        let fm = FileManager.default

        return output.split(separator: "\n").compactMap { line -> Registration? in
            guard let entry = Self.parse(String(line)) else { return nil }

            let exists = fm.fileExists(atPath: entry.path)
            // Apple's own extensions live under /System and are managed by
            // macOS. Several are conditionally installed, so an absent one
            // is not a leftover and cannot be removed.
            let isApple = entry.identifier.hasPrefix("com.apple.")
                || entry.path.hasPrefix("/System/")

            return Registration(
                kind: .appExtension,
                identifier: entry.identifier,
                label: entry.displayName,
                owningBundleID: Self.owningBundle(of: entry.identifier),
                programPath: entry.path,
                targetExists: exists,
                recordPath: nil,
                evidence: exists
                    ? "Registered with PluginKit."
                    : "Registered with PluginKit, but the extension is gone.",
                isSystemOwned: isApple,
                capability: .ok
            )
        }
    }

    struct Entry: Equatable {
        let identifier: String
        let version: String?
        let path: String
        /// PluginKit marks an enabled extension with `+` in the first
        /// column. Recorded because switching one back on afterwards is
        /// the person's decision, not Brim's.
        let isEnabled: Bool

        var displayName: String {
            let leaf = (path as NSString).lastPathComponent
            let name = (leaf as NSString).deletingPathExtension
            return name.isEmpty ? identifier : name
        }
    }

    /// One line of `pluginkit -m -v`.
    ///
    /// Five columns of flags, then tab-separated identifier with version
    /// in brackets, UUID, date and path. The last line is a count, and a
    /// path can contain spaces and non-ASCII, so the path is everything
    /// after the third tab rather than the last whitespace-separated
    /// field.
    static func parse(_ line: String) -> Entry? {
        guard !line.isEmpty else { return nil }
        // " (490 plug-ins)" closes the listing.
        if line.contains("plug-ins)"), !line.contains("\t") {
            return nil
        }

        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 4 else { return nil }

        let flagsAndIdentifier = fields[0]
        let path = fields[3...].joined(separator: "\t")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }

        let flags = String(flagsAndIdentifier.prefix(5))
        let rest = String(flagsAndIdentifier.dropFirst(5))
            .trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        var identifier = rest
        var version: String?
        if rest.hasSuffix(")"), let open = Self.openingParenthesis(closing: rest) {
            identifier = String(rest[rest.startIndex ..< open])
            let inner = String(rest[rest.index(after: open) ..< rest.index(before: rest.endIndex)])
            version = inner == "(null)" ? nil : inner
        }
        guard !identifier.isEmpty else { return nil }

        return Entry(
            identifier: identifier,
            version: version,
            path: path,
            isEnabled: flags.contains("+")
        )
    }

    /// Where the trailing `(version)` starts.
    ///
    /// Matched by balancing from the end rather than by the last opening
    /// bracket, because pluginkit prints a missing version as `((null))`
    /// and the naive search split `com.apple.fskit.msdos((null))` into
    /// the identifier `com.apple.fskit.msdos(` and the version `null)`.
    static func openingParenthesis(closing text: String) -> String.Index? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == ")" {
                depth += 1
            }
            if text[index] == "(" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    /// The application an extension belongs to.
    ///
    /// An extension identifier is conventionally the host's with a suffix,
    /// `net.whatsapp.WhatsApp.Intents` for `net.whatsapp.WhatsApp`. That
    /// is a convention rather than a rule, so it is used only to group
    /// rows; ownership for a removal is decided on the path being inside
    /// the bundle, which `Registration.belongs(to:bundleURL:)` checks.
    static func owningBundle(of identifier: String) -> String? {
        let parts = identifier.split(separator: ".")
        guard parts.count > 3 else { return nil }
        return parts.dropLast().joined(separator: ".")
    }
}
