import BrimCore
import Foundation

extension InstallerReader {
    // MARK: - Application

    /// An application that is not installed: what its bundle declares it
    /// will register, and what it may ask permission for. The same reader
    /// the uninstall uses, so a declaration means the same in both places.
    func readApplication(_ url: URL) -> InstallerPreview {
        let (identity, capabilities) = BundleSurfaceReader.read(at: url, in: root)
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String
        let current = replaced(identifier)
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let app = InstallerPreview.App(
            name: name, identifier: identifier, version: info["CFBundleShortVersionString"] as? String,
            path: url.path, replacesVersion: current?.version, isInstalled: current != nil, icon: icon(url)
        )
        let code = CodeFacts.read(url)
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path
        )) ?? []
        var limits = ["Read from the app itself. What it creates once it runs is not known until then."]
        if !capabilities.completeness.isComplete {
            limits.append("Part of the app could not be read.")
        }
        return InstallerPreview(
            source: url, kind: .application, name: name,
            signature: InstallerSignature(signer: code.signer, team: code.team,
                                          verdict: Self.gatekeeper(url, type: "execute")),
            apps: [app],
            items: Self.declaredItems(capabilities, components: identity.components, bundle: url),
            permissions: Self.permissions(info: info, capabilities: capabilities),
            isSandboxed: code.isSandboxed, updater: DeclaredPermissions.updater(inFrameworks: frameworks),
            limits: limits
        )
    }

    /// What the bundle declares, one row per thing, in the groups a
    /// package's rows use.
    static func declaredItems(
        _ capabilities: CapabilitySurface, components: [IdentitySurface.Component], bundle: URL
    ) -> [InstallerPreview.Item] {
        let source = "Declared inside \(bundle.lastPathComponent), registered when it runs"
        var items: [InstallerPreview.Item] = []
        var seen = Set<String>()
        func add(_ path: String, _ group: InstallerPreview.Group, _ what: String) {
            guard seen.insert("\(group.rawValue)|\(path)").inserted else { return }
            items.append(InstallerPreview.Item(path: path, group: group, what: what, source: source))
        }
        for declaration in capabilities.declarations {
            switch declaration.capability {
            case .launchdJob where declaration.key == "Label":
                add(declaration.path, .background, "Background job")
            case .privilegedHelper:
                add(bundle.path + "/Contents/Library/LaunchServices/" + declaration.value, .background,
                    "Privileged helper")
            case .systemExtension:
                add(declaration.path, .systemExtensions, declaration.key)
            case .appExtension:
                add(declaration.path, .plugIns, "App extension")
            case .fileProvider:
                add(declaration.path, .plugIns, "Cloud files")
            case .bundlePlugin:
                add(declaration.path, .plugIns, "Plug-in")
            default:
                continue
            }
        }
        for component in components where component.path.contains("/Contents/Library/LoginItems/") {
            add(component.path, .background, "Login item")
        }
        return items.sorted { ($0.group, $0.path) < ($1.group, $1.path) }
    }

    /// From the `Info.plist` keys macOS shows in its prompts, and from the
    /// entitlements the bundle reader already found.
    static func permissions(info: [String: Any], capabilities: CapabilitySurface) -> [String] {
        let entitled = [
            "Camera": "Camera", "Microphone": "Microphone", "Bluetooth": "Bluetooth",
            "AppleEvents": "Control other apps", "ScreenCapture": "Screen recording"
        ]
        var names = DeclaredPermissions.names(in: info)
        for declaration in capabilities.declarations where declaration.capability == .privacyGrant {
            if let name = entitled[declaration.value], !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Disk image

    /// Mounted read-only and hidden from Finder, read, and ejected on
    /// every way out. A licence or a password stops it before mounting:
    /// agreeing to a licence is the person's to do, and standard input is
    /// closed so it can never be agreed to by accident.
    func readDiskImage(_ url: URL) throws -> InstallerPreview {
        guard let info = ToolOutput.run("/usr/bin/hdiutil", ["imageinfo", "-plist", url.path], timeout: 30),
              info.status == 0, let facts = Self.plist(info.output) else { throw InstallerReadError.unreadable }
        if Self.flag("Encrypted", in: facts) {
            throw InstallerReadError.encrypted
        }
        if Self.flag("Software License Agreement", in: facts) {
            throw InstallerReadError.licence
        }
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mounts = workspace.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        guard let attached = ToolOutput.run("/usr/bin/hdiutil", [
            "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountrandom", mounts.path,
            url.path
        ], timeout: 120), attached.status == 0, let entities = Self.plist(attached.output)?["system-entities"]
            as? [[String: Any]] else { throw InstallerReadError.unreadable }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        defer { Self.eject(devices) }

        var contents: [InstallerPreview] = []
        for mount in entities.compactMap({ $0["mount-point"] as? String }) {
            let volume = URL(fileURLWithPath: mount)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") && contents.count < 8 {
                let item = volume.appendingPathComponent(name)
                guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                      let kind = Self.kind(of: item), kind != .diskImage else { continue }
                if let preview = try? (kind == .application ? readApplication(item) : readPackage(item)) {
                    contents.append(preview)
                }
            }
        }
        let code = CodeFacts.read(url)
        return InstallerPreview(
            source: url, kind: .diskImage, name: url.deletingPathExtension().lastPathComponent,
            signature: InstallerSignature(signer: code.signer, team: code.team,
                                          verdict: Self.gatekeeper(url, type: "open")),
            limits: contents.isEmpty ? ["No app or package at the top of this disk image."] : [],
            contents: contents
        )
    }

    static func plist(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// A flag anywhere in `imageinfo`'s answer; it nests some under
    /// `Properties` and moves them between releases.
    static func flag(_ key: String, in facts: [String: Any]) -> Bool {
        if let value = facts[key] as? Bool {
            return value
        }
        return facts.values.contains { ($0 as? [String: Any]).map { flag(key, in: $0) } ?? false }
    }

    /// The whole disk first, which takes its volumes with it; then the
    /// rest, forced only if asking did not work.
    static func eject(_ devices: [String]) {
        let ordered = devices.sorted { $0.count < $1.count }
        guard let disk = ordered.first else { return }
        if ToolOutput.run("/usr/bin/hdiutil", ["detach", disk], timeout: 60)?.status != 0 {
            _ = ToolOutput.run("/usr/bin/hdiutil", ["detach", "-force", disk], timeout: 60)
        }
    }
}
