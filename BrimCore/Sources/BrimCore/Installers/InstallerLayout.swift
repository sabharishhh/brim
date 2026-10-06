import Foundation

/// Turns a package's file list into the things a person would name.
///
/// A payload is thousands of paths. What someone wants to know is that it
/// adds an application, a launch daemon and a folder in Application
/// Support. So every path is reduced to the outermost thing the installer
/// *creates*: a bundle is one thing however many files it holds, a launch
/// job is its property list, and anything else is the first folder on the
/// path that is not already on this Mac. A path that is entirely there
/// already is a file being replaced.
public enum InstallerLayout {
    /// One line of `lsbom -p fms`: path, octal mode and, for a file, size.
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let isDirectory: Bool
        public let bytes: Int64

        public init(path: String, isDirectory: Bool, bytes: Int64) {
            self.path = path
            self.isDirectory = isDirectory
            self.bytes = bytes
        }
    }

    /// Reads `lsbom -p fms` output, placing each path under the package's
    /// install location. AppleDouble entries (`._name`) carry a copied
    /// file's extended attributes and are not things anyone installs.
    public static func entries(lsbom text: String, installLocation: String) -> [Entry] {
        let base = installLocation.hasSuffix("/") ? String(installLocation.dropLast()) : installLocation
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            var relative = String(fields[0])
            guard relative != "." else { return nil }
            if relative.hasPrefix("./") {
                relative.removeFirst(2)
            }
            guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0.hasPrefix("._") }),
                  !relative.split(separator: "/").contains("..") else { return nil }
            let mode = Int(fields[1], radix: 8) ?? 0
            let bytes = fields.count > 2 ? Int64(fields[2]) ?? 0 : 0
            return Entry(path: base + "/" + relative, isDirectory: mode & 0o170000 == 0o040000, bytes: bytes)
        }
    }

    /// Extensions that make a folder one thing.
    static let bundleExtensions: Set<String> = [
        "app", "kext", "dext", "systemextension", "plugin", "bundle", "component", "prefpane", "qlgenerator",
        "mdimporter", "framework", "saver", "appex", "driver", "vst", "vst3", "aaxplugin", "xpc", "service",
        "workflow", "wdgt", "mpkg", "pkg"
    ]

    /// Folders where every entry is its own item, however deep the folder.
    static let oneItemFolders: Set<String> = [
        "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
        "/usr/local/bin", "/usr/local/sbin", "/Library/Extensions", "/Library/Fonts",
        "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3", "/Library/Internet Plug-Ins", "/Library/Input Methods",
        "/Library/PreferencePanes", "/Library/QuickLook", "/Library/Spotlight", "/Library/Screen Savers",
        "/Library/Services", "/Library/Frameworks"
    ]

    /// Something the installer creates, with the bytes of everything in it.
    public struct Root: Sendable, Equatable {
        public let path: String
        public let isDirectory: Bool
        public internal(set) var bytes: Int64
        /// Already on this Mac, so the installer replaces it.
        public let exists: Bool
    }

    /// The outermost thing each entry belongs to, in the payload's order.
    public static func roots(of entries: [Entry], exists: (String) -> Bool) -> [Root] {
        var order: [String] = []
        var found: [String: Root] = [:]
        var known: [String: Bool] = [:]
        func there(_ path: String) -> Bool {
            if let answer = known[path] {
                return answer
            }
            let answer = exists(path)
            known[path] = answer
            return answer
        }
        for entry in entries {
            guard let (path, isDirectory) = root(of: entry, exists: there) else { continue }
            if found[path] == nil {
                order.append(path)
                found[path] = Root(path: path, isDirectory: isDirectory, bytes: 0, exists: there(path))
            }
            if !entry.isDirectory {
                found[path]?.bytes += entry.bytes
            }
        }
        return order.compactMap { found[$0] }
    }

    static func root(of entry: Entry, exists: (String) -> Bool) -> (String, Bool)? {
        let parts = entry.path.split(separator: "/").map(String.init)
        // The outermost bundle on the path, wherever it is.
        for index in parts.indices {
            let ext = (parts[index] as NSString).pathExtension.lowercased()
            if bundleExtensions.contains(ext) {
                return ("/" + parts[...index].joined(separator: "/"), true)
            }
        }
        let parent = (entry.path as NSString).deletingLastPathComponent
        if oneItemFolders.contains(parent) {
            return (entry.path, entry.isDirectory)
        }
        // The first folder that is not on this Mac yet.
        var prefix = ""
        for index in parts.indices {
            prefix += "/" + parts[index]
            if !exists(prefix) {
                return (prefix, index < parts.count - 1 || entry.isDirectory)
            }
        }
        // Already here: a file is replaced, a folder is only structure.
        return entry.isDirectory ? nil : (entry.path, false)
    }

    /// What lands in each of macOS's own folders. Read before the
    /// extension, because a launch job's property list says nothing by its
    /// extension.
    static let byFolder: [String: (InstallerPreview.Group, String)] = [
        "/Library/LaunchDaemons": (.background, "Launch daemon, starts with the Mac"),
        "/Library/LaunchAgents": (.background, "Launch agent, starts at every login"),
        "/Library/PrivilegedHelperTools": (.background, "Privileged helper"),
        "/Library/Audio/Plug-Ins/HAL": (.systemExtensions, "Audio driver"),
        "/usr/local/bin": (.commandLine, "Command line tool"),
        "/usr/local/sbin": (.commandLine, "Command line tool"),
        "/Library/Input Methods": (.plugIns, "Input method"),
        "/Library/Internet Plug-Ins": (.plugIns, "Browser plug-in"),
        "/Library/Services": (.plugIns, "Service"),
        "/Library/Fonts": (.files, "Font")
    ]

    static let byExtension: [String: (InstallerPreview.Group, String)] = [
        "kext": (.systemExtensions, "Kernel extension"),
        "dext": (.systemExtensions, "System extension"),
        "systemextension": (.systemExtensions, "System extension"),
        "driver": (.systemExtensions, "Audio driver"),
        "qlgenerator": (.plugIns, "Quick Look plug-in"),
        "mdimporter": (.plugIns, "Spotlight importer"),
        "prefpane": (.plugIns, "Settings pane"),
        "saver": (.plugIns, "Screen saver"),
        "component": (.plugIns, "Audio plug-in"),
        "vst": (.plugIns, "Audio plug-in"),
        "vst3": (.plugIns, "Audio plug-in"),
        "aaxplugin": (.plugIns, "Audio plug-in"),
        "appex": (.plugIns, "App extension"),
        "workflow": (.plugIns, "Service"),
        "framework": (.files, "Framework")
    ]

    /// Which group a created thing belongs to, and what to call it.
    public static func classify(_ path: String, isDirectory: Bool) -> (InstallerPreview.Group, String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if let found = byFolder[parent.path] ?? byExtension[url.pathExtension.lowercased()] {
            return found
        }
        if parent.lastPathComponent == "bin" {
            return (.commandLine, "Command line tool")
        }
        return (.files, isDirectory ? "Folder" : "File")
    }

    /// What an application in the payload carries that it registers once
    /// it runs, read from the paths inside it. Nothing is unpacked, so this
    /// knows a job by its file and not by its label.
    public static func embedded(in app: String, entries: [Entry]) -> [InstallerPreview.Item] {
        let contents = app + "/Contents/"
        let name = (app as NSString).lastPathComponent
        let folders: [EmbeddedFolder] = [
            .init(folder: "Library/LaunchDaemons", group: .background, what: "Background job"),
            .init(folder: "Library/LaunchAgents", group: .background, what: "Background job"),
            .init(folder: "Library/LoginItems", group: .background, what: "Login item"),
            .init(folder: "Library/LaunchServices", group: .background, what: "Privileged helper"),
            .init(folder: "Library/SystemExtensions", group: .systemExtensions, what: "System extension"),
            .init(folder: "PlugIns", group: .plugIns, what: "App extension")
        ]
        var items: [InstallerPreview.Item] = []
        var seen = Set<String>()
        for entry in entries where entry.path.hasPrefix(contents) {
            let inside = String(entry.path.dropFirst(contents.count))
            for embedded in folders where inside.hasPrefix(embedded.folder + "/") {
                let folder = embedded.folder
                let child = inside.dropFirst(folder.count + 1).split(separator: "/").first.map(String.init) ?? ""
                // A job is its property list; anything else in these
                // folders is a resource of the job, not a second one.
                let isJobFolder = folder == "Library/LaunchDaemons" || folder == "Library/LaunchAgents"
                guard !child.isEmpty, !child.hasPrefix("."),
                      !isJobFolder || (child as NSString).pathExtension == "plist",
                      seen.insert(folder + "/" + child).inserted else { continue }
                items.append(InstallerPreview.Item(
                    path: contents + folder + "/" + child, group: embedded.group, what: embedded.what,
                    source: "Inside \(name), registered when it runs"
                ))
            }
        }
        return items
    }

    private struct EmbeddedFolder {
        let folder: String
        let group: InstallerPreview.Group
        let what: String
    }
}
