import BrimCore
import Foundation

/// Which plainly named folders in a system location belong to a third
/// party, and whether that party still has software installed.
///
/// `/Library` is mostly macOS's, under names like `BTServer` and
/// `iLifeMediaBrowser`, so the sweep only ever looked at names shaped like
/// bundle identifiers there. Developers name their folders plainly too:
/// `Microsoft` in `/Library/Logs` kept Teams' logs and AutoUpdate's after
/// both had been removed. A plain name is a developer's when one of three
/// records says so: an installed application, one Brim has seen before, or
/// an installer receipt that put something inside a folder of that name.
/// A name Apple's own applications use is never a third party's.
struct SystemVendors: Sendable {
    enum Claim: Equatable {
        /// Named after one application. Judged like any other entry.
        case application
        /// A developer's folder. Its contents are judged, never the folder.
        case developer
    }

    /// Lowercased names of non-Apple applications on this Mac now.
    let installed: Set<String>
    /// Lowercased names of non-Apple applications Brim has recorded.
    let recorded: Set<String>
    /// Lowercased names of Apple's applications.
    let apple: Set<String>
    /// Folders a non-Apple package installed into, and the folders holding them.
    let packaged: Set<String>
    let packagedParents: Set<String>
    /// Installed and recorded names as `NameKey` compares them.
    let nameKeys: Set<String>
    /// What applications, installed or gone, are themselves called,
    /// including derived names, as `NameKey` compares them.
    let productKeys: Set<String>

    init(
        installed identities: [Identity], recorded: [String: String], past: [Identity] = [],
        packageFolders: [URL], root: FileSystemRoot
    ) {
        func isApples(_ identifier: String?) -> Bool {
            (identifier ?? "").lowercased().hasPrefix("com.apple.")
        }
        installed = Set(identities.filter { !isApples($0.bundleID) }.flatMap { $0.searchNames.map { $0.lowercased() } })
        apple = Set(identities.filter { isApples($0.bundleID) }.flatMap { $0.searchNames.map { $0.lowercased() } })
        self.recorded = Set(recorded.filter { !isApples($0.key) }.values.map { $0.lowercased() }.filter { !$0.isEmpty })
        let depth = root.rootURL.standardizedFileURL.pathComponents.count
        var own = Set<String>(), parents = Set<String>()
        for folder in packageFolders {
            // `Library/<location>/<developer>/<product>`, or `<product>` alone.
            let parts = Array(folder.standardizedFileURL.pathComponents.dropFirst(depth))
            guard parts.count >= 3 else { continue }
            if parts.count >= 4 {
                parents.insert(parts[2].lowercased())
            } else {
                own.insert(parts[2].lowercased())
            }
        }
        packaged = own
        packagedParents = parents
        nameKeys = Set(installed.union(self.recorded).map(NameKey.of).filter { !$0.isEmpty })
        productKeys = Set((identities + past).flatMap { $0.ownNames + $0.derivedNames }
            .map(NameKey.of).filter { !$0.isEmpty })
    }

    func claim(_ folder: String) -> Claim? {
        let name = folder.lowercased()
        let prefix = name + " "
        guard !name.isEmpty, name != "apple", !apple.contains(name),
              !apple.contains(where: { $0.hasPrefix(prefix) })
        else { return nil }
        // A folder that is itself what an application is called is that
        // application's, even when a longer name begins with it.
        // `Application Support/SystemEQ` was opened as though SystemEQ were
        // a developer, because the app was called "SystemEQ for Mac", and
        // nothing inside it was ever offered.
        if productKeys.contains(NameKey.of(name)) {
            return .application
        }
        let names = installed.union(recorded)
        let hasChildren = names.contains { $0.hasPrefix(prefix) && $0.count > prefix.count }
        if packagedParents.contains(name) || hasChildren {
            return .developer
        }
        if packaged.contains(name) || names.contains(name) || nameKeys.contains(NameKey.of(name)) {
            return .application
        }
        return nil
    }

    /// Whether anything this developer makes is installed now.
    func hasInstalled(_ developer: String) -> Bool {
        let name = developer.lowercased()
        return installed.contains(where: { $0 == name || $0.hasPrefix(name + " ") })
    }
}
