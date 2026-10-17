import Foundation

/// Build caches, and how safe each one is to clear. A named list rather than
/// a match on the word "cache", because similar folders differ: deleting
/// `DerivedData` costs a rebuild, deleting the simulator device set loses
/// every simulator. Anything not on the list is left alone.
public struct DeveloperCache: Codable, Sendable, Equatable, Identifiable {
    /// Three classes, which decide what Brim is allowed to do.
    public enum Cost: String, Sendable, Codable {
        /// Regenerable. Brim removes these itself.
        case rebuilt
        /// Owned by a tool with its own cleanup. Brim runs that command, because
        /// removing a module cache by hand leaves the tool confused.
        case refetched
        /// Project dependencies with a restore record. Local changes and offline
        /// copies can still matter, so these go to the Trash.
        case restored
        /// Stateful. Reported and routed, never touched. Xcode archives,
        /// simulator devices and container disk images are always here,
        /// whatever their size.
        case configured

        /// Whether Brim may remove the files directly.
        public var isBrimRemovable: Bool {
            self == .rebuilt || self == .restored
        }
    }

    public let name: String
    public let tool: String
    public let url: URL
    public let sizeBytes: Int64
    /// Nil for older callers that supplied an already measured scalar.
    public let sizeMeasurement: ArtifactSize?
    public let artifactClassification: ArtifactClassification?
    public let cost: Cost
    /// What is in there and what happens without it.
    public let explanation: String
    /// The tool's own cleanup, where it has one. Present only for the
    /// delegated class.
    public let cleanupID: String?
    /// The command as it would be typed, carried so the view can show it
    /// without linking the table that runs it.
    public let cleanupCommand: String?
    public let manualCleanupReason: String?
    /// For a project's build output, when it was last built. Nil for a
    /// tool's shared cache.
    public let lastBuilt: Date?
    public var isProject: Bool {
        lastBuilt != nil
    }

    /// For an update an app downloaded, the installed app it is for.
    public let app: URL?
    public var isUpdateDownload: Bool {
        app != nil
    }

    /// For an old version of a command line tool, the version its command
    /// runs instead.
    public let versionInUse: String?
    public var isOldVersion: Bool {
        versionInUse != nil
    }

    public var id: String {
        url.path
    }

    /// One sentence for VoiceOver. The size is the value and the path is left
    /// out of the label, as in the other lists.
    public var spokenDescription: String {
        SpokenText.sentences([tool, name, explanation])
    }

    public init(
        name: String, tool: String, url: URL, sizeBytes: Int64,
        cost: Cost, explanation: String,
        cleanupID: String? = nil, cleanupCommand: String? = nil, lastBuilt: Date? = nil,
        app: URL? = nil, versionInUse: String? = nil, manualCleanupReason: String? = nil,
        sizeMeasurement: ArtifactSize? = nil,
        artifactClassification: ArtifactClassification? = nil
    ) {
        self.name = name
        self.tool = tool
        self.url = url
        self.sizeBytes = sizeBytes
        self.sizeMeasurement = sizeMeasurement
        self.artifactClassification = artifactClassification
        self.cost = cost
        self.explanation = explanation
        self.cleanupID = cleanupID
        self.cleanupCommand = cleanupCommand
        self.manualCleanupReason = manualCleanupReason
        self.lastBuilt = lastBuilt
        self.app = app
        self.versionInUse = versionInUse
    }

    public func measured(using size: ArtifactSize) -> DeveloperCache {
        DeveloperCache(
            name: name, tool: tool, url: url, sizeBytes: size.allocatedBytes,
            cost: cost, explanation: explanation, cleanupID: cleanupID,
            cleanupCommand: cleanupCommand, lastBuilt: lastBuilt, app: app,
            versionInUse: versionInUse, manualCleanupReason: manualCleanupReason,
            sizeMeasurement: size, artifactClassification: artifactClassification
        )
    }

    public var sizeDescription: String {
        guard let size = sizeMeasurement else { return ByteText.short(sizeBytes) }
        switch size.state {
        case .pending: return "Measuring"
        case .unknown: return "Size unavailable"
        case .partial: return sizeBytes > 0 ? "At least " + ByteText.short(sizeBytes) : "Partial size"
        case .complete: return sizeBytes == 0 && size.logicalBytes > 0 ? "0 bytes allocated" : ByteText.short(sizeBytes)
        }
    }

    public static func estimatedTotal(of caches: [DeveloperCache]) -> Int64 {
        let roots = Set(ArtifactSizer.minimalRoots(caches.map(\.url)).map(\.path))
        var counted = Set<String>()
        return caches.reduce(0) { total, cache in
            let path = cache.url.standardizedFileURL.path
            guard roots.contains(path), counted.insert(path).inserted else { return total }
            return total + cache.sizeBytes
        }
    }
}
