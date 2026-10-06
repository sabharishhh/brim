import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
extension InstallerReader {
    /// `pkgutil --expand` writes each component's `PackageInfo`, `Bom` and
    /// `Scripts` and leaves the payload compressed, so a package of any
    /// size is read in about the time its file list takes to print.
    func readPackage(_ url: URL) throws -> InstallerPreview {
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let expanded = workspace.appendingPathComponent("expanded")
        guard let outcome = ToolOutput.run("/usr/sbin/pkgutil", ["--expand", url.path, expanded.path], timeout: 120),
              outcome.status == 0 else { throw InstallerReadError.unreadable }

        let distribution = (try? String(contentsOf: expanded.appendingPathComponent("Distribution"), encoding: .utf8))
            .flatMap(PackageDistribution.parse)
        var entries: [InstallerLayout.Entry] = []
        var bundles: [(path: String, bundle: PackageComponent.Bundle)] = []
        var scripts: [InstallerPreview.Script] = []
        var unreadable = false
        for folder in Self.componentFolders(in: expanded) {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("PackageInfo"), encoding: .utf8),
                  let component = PackageComponent.parse(text) else { unreadable = true; continue }
            if let listing = ToolOutput.run("/usr/bin/lsbom", ["-p", "fms", folder.appendingPathComponent("Bom").path],
                                            timeout: 60, limit: 128 * 1024 * 1024), listing.status == 0 {
                entries += InstallerLayout.entries(lsbom: listing.output, installLocation: component.installLocation)
            } else {
                unreadable = true
            }
            for bundle in component.bundles {
                bundles.append((Self.placed(bundle.path, under: component.installLocation), bundle))
            }
            scripts += Self.scripts(of: component, in: folder.appendingPathComponent("Scripts"))
        }

        let roots = InstallerLayout.roots(of: entries) { PathObservation.observe($0) != .absent }
        let apps = applications(roots: roots, declared: bundles)
        let items = Self.items(roots: roots, apps: apps, entries: entries)

        let limits = Self.limits(
            hasScripts: !scripts.isEmpty, mayInstallInHome: distribution?.mayInstallInHome == true,
            unreadable: unreadable
        )
        let check = ToolOutput.run("/usr/sbin/pkgutil", ["--check-signature", url.path], timeout: 30)
        let signed = check.flatMap { PackageSignatureText.signer(in: $0.output) }
        return InstallerPreview(
            source: url, kind: .package,
            name: distribution?.title ?? apps.first?.name ?? url.deletingPathExtension().lastPathComponent,
            signature: InstallerSignature(signer: signed?.signer, team: signed?.team,
                                          verdict: Self.gatekeeper(url, type: "install")),
            apps: apps, items: items, scripts: scripts,
            totalBytes: entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.bytes) }, limits: limits
        )
    }

    /// One row for each thing the payload creates, then what each app in it
    /// carries and registers once it runs.
    static func items(
        roots: [InstallerLayout.Root], apps: [InstallerPreview.App], entries: [InstallerLayout.Entry]
    ) -> [InstallerPreview.Item] {
        var items: [InstallerPreview.Item] = []
        for root in roots where URL(fileURLWithPath: root.path).pathExtension.lowercased() != "app" {
            let (group, what) = InstallerLayout.classify(root.path, isDirectory: root.isDirectory)
            items.append(InstallerPreview.Item(path: root.path, group: group, what: what,
                                               source: "From the package's file list", bytes: root.bytes,
                                               exists: root.exists))
        }
        for app in apps {
            items += InstallerLayout.embedded(in: app.path, entries: entries)
        }
        return items
    }

    static func limits(hasScripts: Bool, mayInstallInHome: Bool, unreadable: Bool) -> [String] {
        var limits = ["Lists everything the package can install. It may let you choose less."]
        if hasScripts {
            limits.append("Scripts can do more than their text shows.")
        }
        if mayInstallInHome {
            limits.append("May install into your home folder instead.")
        }
        if unreadable {
            limits.append("Part of the package could not be read.")
        }
        return limits
    }

    /// A product archive keeps one folder per component beside its
    /// `Distribution`; a component package is its own only component.
    static func componentFolders(in expanded: URL) -> [URL] {
        if FileManager.default.fileExists(atPath: expanded.appendingPathComponent("PackageInfo").path) {
            return [expanded]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: expanded.path)) ?? []
        return names.sorted().map { expanded.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("PackageInfo").path) }
    }

    /// `./Applications/Demo.app` under `/`, as an absolute path.
    static func placed(_ relative: String, under location: String) -> String {
        var path = relative
        if path.hasPrefix("./") {
            path.removeFirst(2)
        }
        let base = location.hasSuffix("/") ? String(location.dropLast()) : location
        return base + "/" + path
    }

    /// Applications the payload creates, named and versioned from what
    /// `PackageInfo` declares for each, so nothing has to be unpacked.
    func applications(
        roots: [InstallerLayout.Root], declared: [(path: String, bundle: PackageComponent.Bundle)]
    ) -> [InstallerPreview.App] {
        var paths = roots.map(\.path).filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "app" }
        // A helper application the package puts inside a new folder of its
        // own, such as an updater in Application Support.
        for (path, _) in declared where path.lowercased().hasSuffix(".app") && !paths.contains(path)
            && !paths.contains(where: { path.hasPrefix($0 + "/") }) && !path.contains(".app/") {
            paths.append(path)
        }
        return paths.map { path in
            let bundle = declared.first { $0.path == path }?.bundle
            let current = replaced(bundle?.identifier)
            return InstallerPreview.App(
                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                identifier: bundle?.identifier, version: bundle?.version, path: path,
                replacesVersion: current?.version, isInstalled: current != nil
            )
        }
    }

    static func scripts(of component: PackageComponent, in folder: URL) -> [InstallerPreview.Script] {
        // Older packages run the two standard scripts without naming them.
        let named = component.scripts.isEmpty
            ? ["preinstall", "postinstall"].filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }.map { PackageComponent.Script(name: $0, file: $0) }
            : component.scripts
        return named.compactMap { script in
            let file = folder.appendingPathComponent(script.file).standardizedFileURL
            // The file name comes from the package; it must stay inside it.
            guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                  let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
            let isText = InstallScriptReading.isText(data)
            return InstallerPreview.Script(
                name: script.name, package: component.identifier, runsAsAdministrator: component.runsAsRoot,
                text: isText ? String(bytes: data, encoding: .utf8) : nil
            )
        }
    }
}
