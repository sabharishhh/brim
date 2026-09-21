import Foundation

/// A background job whose whole purpose is to check for new versions of
/// something.
///
/// Worth separating out because these behave differently from other
/// background jobs. Most software that installs an updater never removes
/// it, so they outlive what they came with: a Mac that has had Chrome,
/// Dropbox and Adobe on it at some point tends to keep checking for
/// updates to all three long after. They also wake the machine on a timer,
/// which is a battery cost for software you may not even have.
public struct UpdaterAgent: Sendable, Equatable, Identifiable {

    public let registration: Registration
    /// Who the updater belongs to, in words rather than a reverse domain
    /// identifier.
    public let vendor: String
    /// Whether the software it updates is still on this Mac.
    public let productIsInstalled: Bool

    public var id: String { registration.id }

    public init(registration: Registration, vendor: String, productIsInstalled: Bool) {
        self.registration = registration
        self.vendor = vendor
        self.productIsInstalled = productIsInstalled
    }
}

public enum UpdaterRecogniser {

    /// Updaters Brim can name, by the identifier prefix each uses.
    ///
    /// A named list rather than a search for the word "update", because
    /// that word appears in plenty of jobs that do something else, and
    /// because naming the vendor is the point: "com.google.keystone.agent"
    /// tells a user nothing, "Google" tells them everything.
    private static let known: [(prefix: String, vendor: String)] = [
        ("com.google.keystone", "Google"),
        ("com.google.GoogleUpdater", "Google"),
        ("com.microsoft.autoupdate", "Microsoft"),
        ("com.microsoft.update", "Microsoft"),
        ("com.adobe.ARMDC", "Adobe"),
        ("com.adobe.AdobeCreativeCloud", "Adobe"),
        ("com.adobe.acc", "Adobe"),
        ("com.dropbox.DropboxMacUpdate", "Dropbox"),
        ("com.oracle.java", "Oracle Java"),
        ("org.mozilla.updater", "Mozilla"),
        ("com.brave.Brave", "Brave"),
        ("com.valvesoftware.steamclean", "Steam"),
        ("com.logi.optionsplus.updater", "Logitech"),
        ("com.teamviewer", "TeamViewer"),
        ("com.zoom.ZoomAutoUpdater", "Zoom"),
        ("us.zoom.ZoomAutoUpdater", "Zoom"),
        ("com.docker.helper", "Docker"),
        ("com.jetbrains.toolbox", "JetBrains")
    ]

    /// The vendor behind an identifier, or nil when this is not an updater
    /// Brim recognises.
    public static func vendor(for identifier: String) -> String? {
        let lowered = identifier.lowercased()
        for entry in known where lowered.hasPrefix(entry.prefix.lowercased()) {
            return entry.vendor
        }
        // A generic fallback for the common naming conventions, so an
        // updater Brim has not been taught still lands in the right place.
        guard lowered.contains("update") || lowered.contains("upgrade") else { return nil }
        let parts = identifier.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts[1].capitalized
    }
}
