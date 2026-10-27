import Foundation

/// Relationships already proved by discovery, shared by safety and planning.
enum CompanionRelationships {
    static func bundles(in items: [EvaluatedItem]) -> Set<String> {
        Set(items.compactMap { item in
            let evidence = item.footprintItem.evidence
            guard item.selection == .selected, [.A, .B].contains(evidence.tier),
                  ["CompanionApplicationSource", "InstallerPayloadSource"].contains(evidence.mechanism),
                  evidence.url.pathExtension.lowercased() == "app" else { return nil }
            return evidence.url.resolvingSymlinksInPath().path
        })
    }

    static func identifiers(in paths: Set<String>) -> Set<String> {
        Set(paths.compactMap(identifier).map { $0.lowercased() })
    }

    static func identifier(at path: String) -> String? {
        let info = NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleIdentifier"] as? String
    }

    static func privacyIdentifiers(in items: [EvaluatedItem]) -> [String] {
        let eligible = items.filter {
            $0.footprintItem.capability != .needsHelper || HelperScope.covers($0.footprintItem.evidence.url.path)
        }
        return bundles(in: eligible).compactMap(identifier)
    }

    static func embeddedPrivacyIdentifiers(in identity: Identity) -> [String] {
        let host = identity.bundlePath ?? ""
        return identity.identitySurface?.components.compactMap { component in
            guard component.path.hasPrefix(host + "/"),
                  ["app", "appex", "xpc"].contains(URL(fileURLWithPath: component.path).pathExtension),
                  PathObservation.observe(component.path).isPresent,
                  let identifier = component.bundleIdentifier,
                  identity.searchBundleIdentifiers.contains(identifier) else { return nil }
            return identifier
        } ?? []
    }

    static func includes(_ bundle: URL, subject: String?, companions: Set<String>, root: FileSystemRoot) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        if companions.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        guard let subject else { return false }
        return path == subject || path.hasPrefix(subject + "/")
            || ApplicationBundle.runsInside(bundle, owner: URL(fileURLWithPath: subject), in: root)
    }

    static func dataOwner(of url: URL, identifiers: Set<String>, others: [String: String]) -> String? {
        guard url.pathExtension.lowercased() != "app" else { return nil }
        let name = url.lastPathComponent.lowercased()
        return identifiers.sorted().first(where: { identifier in
            others[identifier] != nil && (name == identifier || name.hasPrefix(identifier + "."))
        }).flatMap { others[$0] }
    }
}
