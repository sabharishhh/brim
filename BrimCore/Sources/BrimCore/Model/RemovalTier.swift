import Foundation

/// How far Brim can take one macOS record during a targeted removal.
public enum RemovalTier: String, Codable, Equatable, Sendable {
    case removable
    case destructiveOnly
    case detectableOnly

    public static func forRegistration(_ kind: Registration.Kind, ownerPresent: Bool) -> RemovalTier {
        switch kind {
        case .backgroundItem:
            // No qualified per-record removal route. A global reset cannot
            // serve as one application's uninstall step.
            .detectableOnly
        case .firewallEntry, .systemExtension, .appExtension, .legacyLoginItem, .keychainItem, .shellProfileLine,
             .configurationProfile:
            .detectableOnly
        case .privacyGrant:
            ownerPresent ? .removable : .detectableOnly
        default:
            .removable
        }
    }

    public static func forCapability(_ capability: DeclaredCapability, ownerPresent: Bool) -> RemovalTier {
        switch capability {
        case .backgroundItem:
            .detectableOnly
        case .firewallEntry, .systemExtension, .appExtension, .vpnConfiguration, .fileProvider, .configurationProfile:
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
    case loginItemsSettings
    case fileProviderOwner
    case firewallSettings
    case deviceManagementSettings
    case systemExtensionsSettings
    case restartForSystemExtension
    case restoreAppForPrivacyReset
    /// Core Audio keeps a device driver loaded until it restarts, so a
    /// removed driver's device stays in the Sound list until then.
    case restartForAudioDevice

    public var sentence: String {
        switch self {
        case .vendorUninstaller:
            "Use the app's uninstaller for any remaining system extensions."
        case .firewallSettings:
            "Review the remaining entry in System Settings > Network > Firewall > Options."
        case .deviceManagementSettings:
            "Review the profile in System Settings > General > Device Management. "
                + "Managed or shared profiles need an administrator."
        case .fileProviderOwner:
            "Finish syncing or export cloud files with the owning app before removing its data."
        case .systemExtensionsSettings:
            "Review remaining extensions in System Settings > General > Login Items & Extensions."
        case .restartForSystemExtension:
            "macOS has scheduled the extension's removal for the next restart. Restart, then check removal again."
        case .loginItemsSettings:
            "Remove the item from Open at Login in System Settings > General > Login Items & Extensions."
        case .vpnSettings:
            "If listed, remove the configuration in System Settings > VPN."
        case .restoreAppForPrivacyReset:
            "If permissions remain, reinstall the app and reset them."
        case .restartForAudioDevice:
            "If its audio device is still listed in Sound settings, restart and check again."
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
