import Foundation

/// One component of an installer package, from its `PackageInfo`.
///
/// `pkgutil --expand` writes this file for every component without
/// unpacking the payload, so everything here is read before anything is
/// installed. A product archive has one per component beside its
/// `Distribution`; a component package has one at its root.
public struct PackageComponent: Sendable, Equatable {
    public struct Bundle: Sendable, Equatable {
        /// Relative to the install location, as the package writes it:
        /// `./Applications/Demo.app`.
        public let path: String
        public let identifier: String?
        public let version: String?
    }

    /// A script `PackageInfo` names, and its file in the `Scripts` folder.
    public struct Script: Sendable, Equatable {
        public let name: String
        public let file: String

        public init(name: String, file: String) {
            self.name = name
            self.file = file
        }
    }

    public let identifier: String
    public let version: String?
    /// Where the payload's `.` lands. `/` for most packages.
    public let installLocation: String
    /// `auth="root"`: the package installs, and runs its scripts, as root.
    public let runsAsRoot: Bool
    public let bundles: [Bundle]
    public let scripts: [Script]

    public static func parse(_ xml: String) -> PackageComponent? {
        guard let document = try? XMLDocument(xmlString: xml, options: []),
              let root = document.rootElement(), root.name == "pkg-info",
              let identifier = root.attribute(forName: "identifier")?.stringValue, !identifier.isEmpty
        else { return nil }
        let location = root.attribute(forName: "install-location")?.stringValue ?? "/"
        let bundles = root.elements(forName: "bundle").compactMap { element -> Bundle? in
            guard let path = element.attribute(forName: "path")?.stringValue else { return nil }
            return Bundle(path: path, identifier: element.attribute(forName: "id")?.stringValue,
                          version: element.attribute(forName: "CFBundleShortVersionString")?.stringValue)
        }
        var scripts: [Script] = []
        for element in root.elements(forName: "scripts").flatMap({ $0.children ?? [] }) {
            guard let element = element as? XMLElement, let name = element.name,
                  let file = element.attribute(forName: "file")?.stringValue else { continue }
            scripts.append(Script(name: name, file: file))
        }
        return PackageComponent(
            identifier: identifier,
            version: root.attribute(forName: "version")?.stringValue,
            installLocation: location.isEmpty ? "/" : location,
            runsAsRoot: root.attribute(forName: "auth")?.stringValue?.lowercased() == "root",
            bundles: bundles,
            scripts: scripts
        )
    }
}

/// The product archive's `Distribution`: its title, and whether it may
/// install into the person's home folder instead of the startup disk.
public struct PackageDistribution: Sendable, Equatable {
    public let title: String?
    public let mayInstallInHome: Bool

    public static func parse(_ xml: String) -> PackageDistribution? {
        guard let document = try? XMLDocument(xmlString: xml, options: []),
              let root = document.rootElement() else { return nil }
        let title = root.elements(forName: "title").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A title like `SU_TITLE` is a key into the package's localisations,
        // not a name.
        let usable = title.flatMap { $0.isEmpty || $0.uppercased() == $0 && $0.contains("_") ? nil : $0 }
        let home = root.elements(forName: "domains").contains {
            $0.attribute(forName: "enable_currentUserHome")?.stringValue == "true"
        }
        return PackageDistribution(title: usable, mayInstallInHome: home)
    }
}

/// `pkgutil --check-signature`, read for who signed the package.
///
/// The certificate chain is numbered from the leaf, so the first line that
/// starts with `1.` names the developer:
/// `1. Developer ID Installer: Example Ltd (ABCDE12345)`.
public enum PackageSignatureText {
    public static func signer(in text: String) -> (signer: String, team: String?)? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("1. ") else { continue }
            let signer = String(trimmed.dropFirst(3))
            return (signer, team(in: signer))
        }
        return nil
    }

    /// The ten characters in the last pair of brackets.
    static func team(in signer: String) -> String? {
        guard signer.hasSuffix(")"), let open = signer.lastIndex(of: "(") else { return nil }
        let team = signer[signer.index(after: open) ..< signer.index(before: signer.endIndex)]
        return team.count == 10 && team.allSatisfy { $0.isUppercase || $0.isNumber } ? String(team) : nil
    }
}
