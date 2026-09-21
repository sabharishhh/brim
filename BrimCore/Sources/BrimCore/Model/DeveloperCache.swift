import Foundation

/// Build caches, and how safe each one is to clear.
///
/// These are the largest reclaimable things on most developer machines and
/// the least visible: Xcode's derived data and device support alone reach
/// tens of gigabytes, and nothing tells you. They are also the easiest
/// category to get wrong, because two directories that look alike can mean
/// very different things. Deleting `DerivedData` costs a rebuild. Deleting
/// the CoreSimulator device set costs every simulator you have set up.
///
/// So this is a named list rather than a pattern match on the word "cache".
/// Each entry says what it is, what clearing it costs, and how it comes
/// back, and anything Brim does not recognise is left alone.
public struct DeveloperCache: Sendable, Equatable, Identifiable {

    /// T-5.7's three classes, which decide what Brim is allowed to do.
    public enum Cost: String, Sendable, Codable {
        /// Regenerable. Brim removes these itself.
        case rebuilt
        /// Owned by a tool that has its own cleanup. Brim runs that command
        /// rather than deleting the directory underneath it, because
        /// removing a module cache by hand leaves the tool confused.
        case refetched
        /// Stateful. Reported and routed, never touched. Xcode archives,
        /// simulator devices and container disk images are always here,
        /// whatever their size.
        case configured

        /// Whether Brim may remove the files directly.
        public var isBrimRemovable: Bool { self == .rebuilt }
    }

    public let name: String
    public let tool: String
    public let url: URL
    public let sizeBytes: Int64
    public let cost: Cost
    /// What is in there and what happens without it.
    public let explanation: String
    /// The tool's own cleanup, where it has one. Present only for the
    /// delegated class.
    public let cleanupID: String?
    /// That command exactly as it would be typed, carried alongside the
    /// identifier so the view can show it without linking the table that
    /// knows how to run it.
    public let cleanupCommand: String?

    public var id: String { url.path }

    /// What a screen reader should say for this row, as one sentence
    /// rather than the five fragments the view is built from. The size
    /// rides as the value and the path is left out of the label, the same
    /// way the other lists handle theirs.
    public var spokenDescription: String {
        SpokenText.sentences([tool, name, explanation])
    }

    public init(
        name: String, tool: String, url: URL, sizeBytes: Int64,
        cost: Cost, explanation: String,
        cleanupID: String? = nil, cleanupCommand: String? = nil
    ) {
        self.name = name
        self.tool = tool
        self.url = url
        self.sizeBytes = sizeBytes
        self.cost = cost
        self.explanation = explanation
        self.cleanupID = cleanupID
        self.cleanupCommand = cleanupCommand
    }
}
