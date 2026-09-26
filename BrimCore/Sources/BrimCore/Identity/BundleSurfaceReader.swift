import Foundation
import Security

/// Reads metadata in bundle packaging locations. It never searches user documents
/// or follows a link outside the containing application.
public enum BundleSurfaceReader {
    public static func read(at bundle: URL, in root: FileSystemRoot) -> (IdentitySurface, CapabilitySurface) {
        read(at: bundle, in: root, budget: ScanBudget(total: 5), signature: Signature.read)
    }

    struct Signature {
        var identifier: String?
        var team: String?
        var entitlements: [String: Any] = [:]
        var gap: String?

        static func read(_ url: URL) -> Signature {
            var code: SecStaticCode?
            let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            guard created == errSecSuccess, let code else {
                return Signature(gap: "Code signature unavailable.")
            }
            var dictionary: CFDictionary?
            let wanted = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            let status = SecCodeCopySigningInformation(code, wanted, &dictionary)
            guard status == errSecSuccess, let values = dictionary as? [String: Any] else {
                return Signature(gap: status == errSecCSUnsigned ? "Unsigned code." : "Code signature unavailable.")
            }
            let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            // CSCommon.h defines kSecCodeSignatureAdhoc as 0x0002, but does
            // not export the symbol to Swift.
            let adHocFlag: UInt32 = 0x0002
            if flags & adHocFlag != 0 {
                return Signature(gap: "Ad-hoc signature.")
            }
            let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
            guard valid == errSecSuccess else {
                return Signature(gap: valid == errSecCSUnsigned ? "Unsigned code." : "Code signature could not be verified.")
            }
            return Signature(
                identifier: values[kSecCodeInfoIdentifier as String] as? String,
                team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            )
        }
    }

    static func read(
        at bundle: URL, in root: FileSystemRoot, budget: ScanBudget,
        signature: (URL) -> Signature
    ) -> (IdentitySurface, CapabilitySurface) {
        var reader = Reader(bundle: bundle, root: root, budget: budget)
        reader.visit(bundle, signature: signature)
        return (
            IdentitySurface(bundlePath: bundle.path, components: reader.components,
                            helperRequirements: reader.helperRequirements),
            CapabilitySurface(declarations: reader.declarations, signatureGaps: reader.signatureGaps,
                              unreadable: Array(reader.unreadable).sorted(), timedOut: Array(reader.timedOut).sorted())
        )
    }

    private struct Reader {
        let bundle: URL
        let root: FileSystemRoot
        let budget: ScanBudget
        var components: [IdentitySurface.Component] = []
        var declarations: [CapabilitySurface.Declaration] = []
        var signatureGaps: [CapabilitySurface.Gap] = []
        var helperRequirements: [String: String] = [:]
        var unreadable = Set<String>()
        var timedOut = Set<String>()
        var visited = Set<String>()

        private static let codeExtensions: Set<String> = [
            "app", "xpc", "appex", "systemextension", "framework", "component", "plugin", "bundle",
            "qlgenerator", "mdimporter", "prefpane", "service", "saver", "vst", "vst3", "aaxplugin"
        ]
        private static let packagingFolders = [
            "Contents/Frameworks", "Contents/PlugIns", "Contents/Plugins", "Contents/XPCServices",
            "Contents/Helpers", "Contents/Library/LoginItems", "Contents/Library/SystemExtensions",
            "Contents/Library/LaunchServices", "Helpers", "XPCServices", "PlugIns"
        ]

        mutating func visit(_ url: URL, signature: (URL) -> Signature) {
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            let boundary = bundle.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPath = root.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard Self.contains(real, within: boundary), Self.contains(real, within: rootPath) else {
                unreadable.insert(url.path)
                return
            }
            guard visited.insert(real).inserted else { return }
            guard !budget.hasRunOut, visited.count <= 512 else { timedOut.insert(url.path); return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                unreadable.insert(url.path)
                return
            }
            let info = isDirectory.boolValue ? readInfo(url) : [:]
            let signing = signature(url)
            if let reason = signing.gap {
                signatureGaps.append(.init(path: url.path, reason: reason))
            }
            // Invalid, unsigned and ad-hoc signatures cannot contribute entitlements.
            let entitlements = signing.gap == nil ? signing.entitlements : [:]
            let bundleID = Self.component(info["CFBundleIdentifier"] as? String) ?? Self.component(signing.identifier)
            let groups = Self.strings(entitlements["com.apple.security.application-groups"])
                .filter(IdentitySurface.isPathComponent)
            let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
            let schemes = urlTypes.flatMap { Self.strings($0["CFBundleURLSchemes"]) }
            let types = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
                .compactMap { $0["UTTypeIdentifier"] as? String }
            components.append(.init(
                path: url.path, bundleIdentifier: bundleID,
                name: url.deletingPathExtension().lastPathComponent,
                bundleName: Self.component(info["CFBundleName"] as? String),
                signingIdentifier: signing.gap == nil ? Self.component(signing.identifier) : nil,
                displayName: Self.component(info["CFBundleDisplayName"] as? String),
                executableName: Self.component(info["CFBundleExecutable"] as? String),
                teamIdentifier: signing.gap == nil ? signing.team : nil,
                groups: groups, urlSchemes: schemes.sorted(), exportedTypes: types.sorted()
            ))
            collect(info: info, entitlements: entitlements, at: url, isDirectory: isDirectory.boolValue)
            guard isDirectory.boolValue else { return }

            for folder in Self.packagingFolders {
                for child in entries(url.appendingPathComponent(folder)) {
                    let isRawHelper = folder.hasSuffix("LaunchServices") && child.pathExtension != "plist"
                    if Self.codeExtensions.contains(child.pathExtension.lowercased()) || isRawHelper {
                        visit(child, signature: signature)
                    }
                }
            }
            // Framework helpers may live in a concrete version rather than at the root.
            if url.pathExtension.lowercased() == "framework" {
                for version in entries(url.appendingPathComponent("Versions")) where version.lastPathComponent != "Current" {
                    for folder in ["Helpers", "XPCServices", "PlugIns", "Frameworks"] {
                        for child in entries(version.appendingPathComponent(folder)) {
                            if Self.codeExtensions.contains(child.pathExtension.lowercased()) {
                                visit(child, signature: signature)
                            }
                        }
                    }
                }
            }
        }

        mutating func readInfo(_ url: URL) -> [String: Any] {
            for relative in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
                let plist = url.appendingPathComponent(relative)
                let real = plist.resolvingSymlinksInPath().path
                guard Self.contains(real, within: bundle.resolvingSymlinksInPath().path) else {
                    unreadable.insert(plist.path)
                    continue
                }
                do {
                    let data = try Data(contentsOf: plist)
                    guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                        as? [String: Any] else { unreadable.insert(plist.path); return [:] }
                    return info
                } catch {
                    if Self.isMissing(error) {
                        continue
                    }
                    // A raw helper binary has no directory-based Info.plist.
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                        return [:]
                    }
                    unreadable.insert(plist.path)
                    return [:]
                }
            }
            if Self.codeExtensions.contains(url.pathExtension.lowercased()) {
                unreadable.insert(url.appendingPathComponent("Contents/Info.plist").path)
            }
            return [:]
        }

        mutating func entries(_ url: URL) -> [URL] {
            guard !budget.hasRunOut else { timedOut.insert(url.path); return [] }
            let real = url.resolvingSymlinksInPath().path
            guard Self.contains(real, within: bundle.resolvingSymlinksInPath().path) else {
                unreadable.insert(url.path)
                return []
            }
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                guard names.count <= 2048 else { timedOut.insert(url.path); return [] }
                return names.filter { !$0.hasPrefix(".") }.map { url.appendingPathComponent($0) }
            } catch {
                if !Self.isMissing(error) {
                    unreadable.insert(url.path)
                }
                return []
            }
        }

        mutating func collect(info: [String: Any], entitlements: [String: Any], at url: URL,
                              isDirectory: Bool)
        {
            func enabled(_ key: String) -> Bool {
                if let flag = entitlements[key] as? Bool {
                    return flag
                }
                return !Self.strings(entitlements[key]).isEmpty
            }
            let path = url.path
            let extensionInfo = info["NSExtension"] as? [String: Any]
            let extensionPoint = extensionInfo?["NSExtensionPointIdentifier"] as? String ?? ""
            let providers = info["NEProviderClasses"] as? [String: Any] ?? [:]
            let networkEntitlement = "com.apple.developer.networking.networkextension"
            let network = !providers.isEmpty || extensionPoint.hasPrefix("com.apple.networkextension") || enabled(networkEntitlement)
            if network {
                add(.systemExtension, key: "Network extension", value: extensionPoint, path: path)
                add(.vpnConfiguration, key: "Network extension", value: extensionPoint, path: path)
            }
            if url.pathExtension == "systemextension" || enabled("com.apple.developer.system-extension.install") {
                add(.systemExtension, key: "System extension", value: url.lastPathComponent, path: path)
            }
            if extensionInfo != nil || info["EXAppExtensionAttributes"] != nil || url.pathExtension == "appex" {
                add(.appExtension, key: "NSExtension", value: extensionPoint, path: path)
            }
            let helpers = info["SMPrivilegedExecutables"] as? [String: String] ?? [:]
            for name in helpers.keys.sorted() where IdentitySurface.isPathComponent(name) {
                helperRequirements[name] = helpers[name]
                add(.privilegedHelper, key: "SMPrivilegedExecutables", value: name, path: path)
                add(.launchdJob, key: "SMPrivilegedExecutables", value: name, path: path)
            }
            if isDirectory {
                for helper in entries(url.appendingPathComponent("Contents/Library/LaunchServices")) {
                    add(.privilegedHelper, key: "Contents/Library/LaunchServices", value: helper.lastPathComponent, path: path)
                }
                for directory in ["Contents/Library/LaunchDaemons", "Contents/Library/LaunchAgents"] {
                    for plist in entries(url.appendingPathComponent(directory)) where plist.pathExtension == "plist" {
                        do {
                            let data = try Data(contentsOf: plist)
                            let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                            if let label = Self.component(values?["Label"] as? String) {
                                add(.launchdJob, key: "Label", value: label, path: plist.path)
                            } else {
                                unreadable.insert(plist.path)
                            }
                        } catch { unreadable.insert(plist.path) }
                    }
                }
            }
            let privacyEntitlements = [
                "com.apple.security.device.camera": "Camera",
                "com.apple.security.device.audio-input": "Microphone",
                "com.apple.security.device.microphone": "Microphone",
                "com.apple.security.device.bluetooth": "Bluetooth",
                "com.apple.security.automation.apple-events": "AppleEvents",
                "com.apple.developer.persistent-content-capture": "ScreenCapture",
                "com.apple.developer.screen-capture.include-passthrough": "ScreenCapture"
            ]
            for key in privacyEntitlements.keys.sorted() where enabled(key) {
                add(.privacyGrant, key: key, value: privacyEntitlements[key]!, path: path)
            }
            let privacyDescriptions = [
                "NSCameraUsageDescription": "Camera", "NSMicrophoneUsageDescription": "Microphone",
                "NSAppleEventsUsageDescription": "AppleEvents", "NSContactsUsageDescription": "AddressBook",
                "NSCalendarsUsageDescription": "Calendar", "NSCalendarsFullAccessUsageDescription": "Calendar",
                "NSRemindersUsageDescription": "Reminders", "NSPhotoLibraryUsageDescription": "Photos",
                "NSBluetoothAlwaysUsageDescription": "Bluetooth", "NSLocationUsageDescription": "Location"
            ]
            for key in privacyDescriptions.keys.sorted() where info[key] is String {
                add(.privacyGrant, key: key, value: privacyDescriptions[key]!, path: path)
            }
            for type in info["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
                for scheme in Self.strings(type["CFBundleURLSchemes"]) {
                    add(.launchServices, key: "CFBundleURLSchemes", value: scheme, path: path)
                }
            }
            for type in info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [] {
                if let identifier = type["UTTypeIdentifier"] as? String {
                    add(.launchServices, key: "UTTypeIdentifier", value: identifier, path: path)
                }
            }
            for group in Self.strings(entitlements["com.apple.security.application-groups"]) {
                if IdentitySurface.isPathComponent(group) {
                    add(.applicationGroups, key: "com.apple.security.application-groups", value: group, path: path)
                }
            }
            if info["AudioComponents"] != nil || ["component", "vst", "vst3", "aaxplugin", "plugin"].contains(url.pathExtension.lowercased()) {
                add(.bundlePlugin, key: "Plug-in component", value: url.lastPathComponent, path: path)
            }
            if isDirectory {
                let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
                if FileManager.default.fileExists(atPath: receipt.path) {
                    add(.installationRecords, key: "App Store receipt", value: receipt.path, path: path)
                }
            }
            if url.resolvingSymlinksInPath().pathComponents.contains("Caskroom") {
                add(.installationRecords, key: "Caskroom", value: url.resolvingSymlinksInPath().path, path: path)
            }
        }

        mutating func add(_ capability: DeclaredCapability, key: String, value: String, path: String) {
            declarations.append(.init(capability, key: key, value: value, path: path))
        }

        static func component(_ value: String?) -> String? {
            value.flatMap { IdentitySurface.isPathComponent($0) ? $0 : nil }
        }

        static func strings(_ value: Any?) -> [String] {
            if let values = value as? [String] {
                return values.filter { !$0.isEmpty }
            }
            return (value as? String).map { $0.isEmpty ? [] : [$0] } ?? []
        }

        static func contains(_ path: String, within root: String) -> Bool {
            root == "/" || path == root || path.hasPrefix(root + "/")
        }

        static func isMissing(_ error: Error) -> Bool {
            let error = error as NSError
            return (error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        }
    }
}
