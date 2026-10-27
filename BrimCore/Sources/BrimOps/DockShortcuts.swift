import AppKit
import BrimCore
import Foundation

/// Removes only persistent Dock tiles whose file URL names the reviewed app
/// path. Labels and bundle identifiers cannot distinguish installed copies.
public enum DockShortcuts {
    private static var domain: CFString {
        "com.apple.dock" as CFString
    }

    private static var key: CFString {
        "persistent-apps" as CFString
    }

    public struct Client: Sendable {
        public var remove: @Sendable (String) async throws -> Void

        public init(remove: @escaping @Sendable (String) async throws -> Void = { _ in
            throw CocoaError(.featureUnsupported)
        }) {
            self.remove = remove
        }

        public init(root: FileSystemRoot) {
            remove = { path in try await DockShortcuts.remove(path: path, in: root) }
        }
    }

    public static func pinnedPaths(in root: FileSystemRoot) throws -> Set<String> {
        try Set(tiles(in: root).compactMap(path(of:)))
    }

    /// Kept pure for matching fixtures, including encoded URLs and a second
    /// installation with the same label.
    public static func path(of tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String else { return nil }
        let url: URL
        if string.hasPrefix("/") {
            url = URL(fileURLWithPath: string)
        } else {
            guard let parsed = URL(string: string), parsed.isFileURL,
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost" else { return nil }
            url = parsed
        }
        return url.standardizedFileURL.path
    }

    private static func preferencesFile(in root: FileSystemRoot) -> URL {
        root.url(for: .userLibrary).appendingPathComponent("Preferences/com.apple.dock.plist")
    }

    private static func tiles(in root: FileSystemRoot) throws -> [[String: Any]] {
        let value: Any?
        if root.rootURL.standardizedFileURL.path == "/" {
            guard CFPreferencesAppSynchronize(domain) else { throw CocoaError(.fileReadUnknown) }
            value = CFPreferencesCopyAppValue(key, domain)
        } else {
            let file = preferencesFile(in: root)
            if PathObservation.observe(file.path).isAbsent {
                return []
            }
            let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
            guard let dictionary = dictionary as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            value = dictionary["persistent-apps"]
        }
        guard let value else { return [] }
        guard let tiles = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        return tiles
    }

    private static func remove(path: String, in root: FileSystemRoot) async throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "app",
              PathObservation.observe(path).isAbsent else { throw CocoaError(.fileWriteNoPermission) }
        let original = try tiles(in: root)
        let remaining = original.filter { self.path(of: $0) != URL(fileURLWithPath: path).standardizedFileURL.path }
        guard remaining.count != original.count else { return }
        if root.rootURL.standardizedFileURL.path == "/" {
            // Regular tests must never edit the person's Dock or terminate it.
            guard NSClassFromString("XCTestCase") == nil,
                  !CFPreferencesAppValueIsForced(key, domain) else { throw CocoaError(.fileWriteNoPermission) }
            CFPreferencesSetAppValue(key, remaining as CFArray, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw CocoaError(.fileWriteUnknown) }
            // Dock reloads its preferences when macOS relaunches it. Address
            // only this user's Dock through AppKit, never cfprefsd or other users.
            try await MainActor.run {
                for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
                    guard dock.terminate() else { throw CocoaError(.fileWriteUnknown) }
                }
            }
        } else {
            let file = preferencesFile(in: root)
            var dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
                as? [String: Any] ?? [:]
            dictionary["persistent-apps"] = remaining
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
                .write(to: file, options: .atomic)
        }
        guard try !pinnedPaths(in: root).contains(path) else { throw CocoaError(.fileWriteUnknown) }
    }
}
