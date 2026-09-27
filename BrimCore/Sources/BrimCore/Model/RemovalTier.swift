import Foundation

/// How far Brim can take one macOS record during a targeted removal.
public enum RemovalTier: String, Codable, Equatable, Sendable {
    case removable
    case destructiveOnly
    case detectableOnly

    public static func forRegistration(_ kind: Registration.Kind, ownerPresent: Bool) -> RemovalTier {
        switch kind {
        case .backgroundItem:
            // There is no per-item removal API. A machine-wide reset would
            // remove every application's background registration.
            .destructiveOnly
        case .systemExtension, .keychainItem, .shellProfileLine:
            .detectableOnly
        case .privacyGrant:
            ownerPresent ? .removable : .detectableOnly
        default:
            .removable
        }
    }

    public static func forCapability(_ capability: DeclaredCapability, ownerPresent: Bool) -> RemovalTier {
        switch capability {
        case .systemExtension, .vpnConfiguration:
            .detectableOnly
        case .privacyGrant:
            ownerPresent ? .removable : .detectableOnly
        default:
            .removable
        }
    }
}

/// A single supported route for a record Brim cannot remove itself.
public enum RemovalFollowUp: String, Codable, Hashable, Sendable {
    case vendorUninstaller
    case vpnSettings
    case restoreAppForPrivacyReset

    public var sentence: String {
        switch self {
        case .vendorUninstaller:
            "Use the app's uninstaller for any remaining system extensions."
        case .vpnSettings:
            "If listed, remove the configuration in System Settings > VPN."
        case .restoreAppForPrivacyReset:
            "If permissions remain, reinstall the app and reset them."
        }
    }
}

public extension CapabilitySearchReport {
    /// Advice is conditional where macOS does not expose the record for a
    /// second check. An unavailable read never becomes a claim of presence.
    func followUps(
        survivingSystemExtensionIDs: Set<String>?,
        privacyResetFailedAfterRemoval: Bool
    ) -> [RemovalFollowUp] {
        var actions: [RemovalFollowUp] = []
        let system = checks.first { $0.capability == .systemExtension }
        if let system, !system.registrations.isEmpty {
            let stillPresent = survivingSystemExtensionIDs == nil
                || system.registrations.contains {
                    survivingSystemExtensionIDs?.contains($0.identifier) == true
                }
            if stillPresent {
                actions.append(.vendorUninstaller)
            }
        }
        if checks.contains(where: {
            $0.capability == .vpnConfiguration && $0.declaration == .declared
        }) {
            actions.append(.vpnSettings)
        }
        if privacyResetFailedAfterRemoval {
            actions.append(.restoreAppForPrivacyReset)
        }
        return actions
    }
}
