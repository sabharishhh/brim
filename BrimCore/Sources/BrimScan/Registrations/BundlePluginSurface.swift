import BrimCore
import Foundation

/// The smaller plug-in folders macOS watches, which differ only by name:
/// preference panes, Quick Look generators, Spotlight importers, Services,
/// Automator actions, colour pickers, screen savers, Internet plug-ins,
/// Audio Units, StartupItems and kernel extensions. Each row names its
/// folder. Fonts are left out: no app owns a font.
public struct BundlePluginSurface: RegistrationSurface {
    public let kind: Registration.Kind = .bundlePlugin

    /// One folder macOS watches, and what a person would call the things
    /// inside it.
    struct Folder {
        let path: String
        /// Relative to the user's home when true.
        let inHome: Bool
        let singular: String
        /// Only bundles with these extensions count. Empty means anything.
        let extensions: Set<String>
    }

    static let folders: [Folder] = [
        Folder(path: "Library/PreferencePanes", inHome: true,
               singular: "preference pane", extensions: ["prefPane"]),
        Folder(path: "Library/PreferencePanes", inHome: false,
               singular: "preference pane", extensions: ["prefPane"]),
        Folder(path: "Library/QuickLook", inHome: true,
               singular: "Quick Look generator", extensions: ["qlgenerator"]),
        Folder(path: "Library/QuickLook", inHome: false,
               singular: "Quick Look generator", extensions: ["qlgenerator"]),
        Folder(path: "Library/Spotlight", inHome: true,
               singular: "Spotlight importer", extensions: ["mdimporter"]),
        Folder(path: "Library/Spotlight", inHome: false,
               singular: "Spotlight importer", extensions: ["mdimporter"]),
        Folder(path: "Library/Services", inHome: true,
               singular: "Services menu item", extensions: ["service", "workflow"]),
        Folder(path: "Library/Services", inHome: false,
               singular: "Services menu item", extensions: ["service", "workflow"]),
        Folder(path: "Library/Automator", inHome: true,
               singular: "Automator action", extensions: ["action"]),
        Folder(path: "Library/Automator", inHome: false,
               singular: "Automator action", extensions: ["action"]),
        Folder(path: "Library/ColorPickers", inHome: true,
               singular: "colour picker", extensions: ["colorPicker"]),
        Folder(path: "Library/ColorPickers", inHome: false,
               singular: "colour picker", extensions: ["colorPicker"]),
        Folder(path: "Library/Screen Savers", inHome: true,
               singular: "screen saver", extensions: ["saver", "qtz"]),
        Folder(path: "Library/Screen Savers", inHome: false,
               singular: "screen saver", extensions: ["saver", "qtz"]),
        Folder(path: "Library/Internet Plug-Ins", inHome: true,
               singular: "Internet plug-in", extensions: ["plugin", "bundle"]),
        Folder(path: "Library/Internet Plug-Ins", inHome: false,
               singular: "Internet plug-in", extensions: ["plugin", "bundle"]),
        Folder(path: "Library/Audio/Plug-Ins/Components", inHome: false,
               singular: "Audio Unit", extensions: ["component"]),
        Folder(path: "Library/Audio/Plug-Ins/VST", inHome: false,
               singular: "VST plug-in", extensions: ["vst"]),
        Folder(path: "Library/Audio/Plug-Ins/VST3", inHome: false,
               singular: "VST3 plug-in", extensions: ["vst3"]),
        Folder(path: "Library/Audio/Plug-Ins/HAL", inHome: false,
               singular: "audio device plug-in", extensions: ["driver", "plugin"]),
        Folder(path: "Library/StartupItems", inHome: false,
               singular: "startup item", extensions: []),
        Folder(path: "Library/Extensions", inHome: false,
               singular: "kernel extension", extensions: ["kext"])
    ]

    public init() {}

    private func url(for folder: Folder, in root: FileSystemRoot) -> URL {
        folder.inHome
            ? root.url(for: .userLibrary).deletingLastPathComponent()
            .appendingPathComponent(folder.path)
            : root.rootURL.appendingPathComponent(folder.path)
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        let fm = FileManager.default
        let anyReadable = Self.folders.contains {
            let path = url(for: $0, in: root).path
            return fm.fileExists(atPath: path) && fm.isReadableFile(atPath: path)
        }
        // None existing is a normal, complete answer on a clean Mac.
        return anyReadable || !Self.folders.contains(where: {
            fm.fileExists(atPath: url(for: $0, in: root).path)
        })
            ? .available(kind)
            : .unavailable(kind, "The plug-in folders could not be read.", absence: .needsPermission)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        await snapshot(in: root).registrations
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        var scopes: [RegistrationCoverage.Scope] = []
        var results: [Registration] = []
        for folder in Self.folders {
            let directory = url(for: folder, in: root)
            let names: [String]
            switch DirectoryEntries.read(directory) {
            case .absent: names = []
            case let .listed(entries): names = entries
            case .refused:
                scopes.append(.init(namespace: directory.path, available: false))
                continue
            }
            scopes.append(.init(namespace: directory.path, available: true))
            for name in names.sorted() where !name.hasPrefix(".") {
                let itemExtension = (name as NSString).pathExtension
                if !folder.extensions.isEmpty, !folder.extensions.contains(itemExtension) {
                    continue
                }
                let item = directory.appendingPathComponent(name)
                let identifier = Self.bundleIdentifier(at: item) ?? item.path

                results.append(Registration(
                    kind: .bundlePlugin,
                    identifier: identifier,
                    label: (name as NSString).deletingPathExtension,
                    owningBundleID: Self.bundleIdentifier(at: item),
                    programPath: item.path,
                    // The file was just enumerated. Whether its app is gone is the uninstall's
                    // question, through `belongs(to:bundleURL:)`.
                    targetExists: true,
                    recordPath: item.path,
                    evidence: "A \(folder.singular) in \(Self.readablePath(directory.path)). "
                        + "Available to macOS from that folder.",
                    isSystemOwned: directory.path.hasPrefix("/System/"),
                    capability: RemovalCapability.forDeleting(item.path),
                    targetPresence: PathObservation.observe(item.path)
                ))
            }
        }
        let complete = scopes.allSatisfy(\.available)
        return RegistrationSnapshot(registrations: results, coverage: RegistrationCoverage(
            kind: kind, available: complete,
            limitation: complete ? nil : "A plug-in folder could not be read.", scopes: scopes
        ))
    }

    /// A path a person recognises, with their home written as `~`.
    static func readablePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func bundleIdentifier(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return parsed["CFBundleIdentifier"] as? String
    }
}
