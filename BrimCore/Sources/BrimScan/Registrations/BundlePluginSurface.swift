import Foundation
import BrimCore

/// The dozen smaller plug-in folders, which differ only in their name.
///
/// Preference panes, Quick Look generators, Spotlight importers, Services,
/// Automator actions, colour pickers, screen savers, Internet plug-ins,
/// Audio Units, StartupItems and kernel extensions. B10 lists them
/// separately; they are one surface, because the mechanism is identical
/// in every case: a bundle dropped in a folder macOS watches.
///
/// Each is enumerated with the folder named in the row, because "Adobe
/// left a preference pane" is what a person reasons about and
/// "kind 17" is not.
///
/// **Fonts are deliberately not here.** They are in B10's list, and this
/// Mac has eighty-five of them. A font has no owning application and
/// nothing about it is ever a leftover, so including them would add
/// eighty-five rows of noise to a list whose value is that everything in
/// it is worth reading.
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
               singular: "kernel extension", extensions: ["kext"]),
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
        // None of them existing is a normal, complete answer on a clean
        // Mac, so this reports available rather than crying gap.
        return anyReadable || !Self.folders.contains(where: {
            fm.fileExists(atPath: url(for: $0, in: root).path)
        })
            ? .available(kind)
            : .unavailable(kind, "The plug-in folders could not be read.", absence: .needsPermission)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        let fm = FileManager.default
        var results: [Registration] = []

        for folder in Self.folders {
            let directory = url(for: folder, in: root)
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
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
                    // The file is right there; it was just enumerated. A
                    // plug-in is a leftover because its application is
                    // gone, and proving that is the uninstall's job
                    // through `belongs(to:bundleURL:)`, not a guess here.
                    targetExists: true,
                    recordPath: item.path,
                    evidence: "A \(folder.singular) in \(Self.readablePath(directory.path)). "
                            + "macOS loads it from there whether or not the application that "
                            + "installed it is still here.",
                    isSystemOwned: directory.path.hasPrefix("/System/"),
                    capability: RemovalCapability.forDeleting(item.path)
                ))
            }
        }
        return results
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
