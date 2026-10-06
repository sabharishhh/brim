import Foundation

/// The applications in the usual folders, by the names a log can give them.
///
/// The power log names a process by its executable and a request made on an
/// application's behalf by its identifier. Neither is what a person calls
/// the app, so each is looked up against the bundles themselves. A name two
/// applications share is dropped rather than guessed between, and a process
/// no application answers to is macOS's own and is not listed.
public struct ApplicationNames: Sendable {
    public struct App: Sendable, Equatable {
        public let name: String
        public let bundlePath: String
    }

    /// One bundle as read from the disk.
    public struct Bundle: Sendable {
        public let name: String
        public let path: String
        public let executable: String?
        public let identifier: String?

        public init(name: String, path: String, executable: String?, identifier: String?) {
            self.name = name
            self.path = path
            self.executable = executable
            self.identifier = identifier
        }
    }

    /// An application and how long it asked the Mac to stay awake.
    public struct Held: Sendable, Equatable {
        public let app: App
        public let seconds: TimeInterval
    }

    private let byExecutable: [String: App]
    private let byIdentifier: [String: App]

    public init(_ bundles: [Bundle]) {
        var executables: [String: App?] = [:]
        var identifiers: [String: App] = [:]
        for bundle in bundles {
            if let identifier = bundle.identifier, identifiers[identifier.lowercased()] != nil {
                // The same app reached twice, as Safari is through
                // /Applications and through the system's own copy.
                continue
            }
            let app = App(name: bundle.name, bundlePath: bundle.path)
            if let executable = bundle.executable {
                // A second app with the same executable makes the name
                // ambiguous for both.
                executables[executable] = executables[executable] == nil ? app : .some(nil)
            }
            if let identifier = bundle.identifier {
                identifiers[identifier.lowercased()] = app
            }
        }
        byExecutable = executables.compactMapValues { $0 }
        byIdentifier = identifiers
    }

    public func app(for request: PowerHistory.Request) -> App? {
        if request.isIdentifier {
            return byIdentifier[request.requester.lowercased()]
        }
        if let exact = byExecutable[request.requester] {
            return exact
        }
        // The log cuts process names at 31 characters.
        guard request.requester.count >= 31 else { return nil }
        let matches = byExecutable.filter { $0.key.hasPrefix(request.requester) }
        return matches.count == 1 ? matches.first?.value : nil
    }

    /// Reads the bundles in the Applications folders, one subfolder deep.
    public static func installed() -> ApplicationNames {
        let fileManager = FileManager.default
        var folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        if let entries = try? fileManager.contentsOfDirectory(atPath: "/Applications") {
            folders += entries.filter { !$0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { "/Applications/" + $0 }
        }
        var bundles: [Bundle] = []
        for folder in folders {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: folder) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = folder + "/" + entry
                guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]
                else { continue }
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? String(entry.dropLast(4))
                bundles.append(Bundle(
                    name: name, path: path,
                    executable: info["CFBundleExecutable"] as? String,
                    identifier: info["CFBundleIdentifier"] as? String
                ))
            }
        }
        return ApplicationNames(bundles)
    }
}
