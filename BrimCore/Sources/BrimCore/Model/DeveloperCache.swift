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

    /// What happens if you clear it.
    public enum Cost: String, Sendable, Codable {
        /// Rebuilt or re-downloaded automatically. Costs time, nothing else.
        case rebuilt
        /// Re-downloaded from the network, so it costs time and bandwidth.
        case refetched
        /// Set up by hand. Clearing it loses configuration.
        case configured
    }

    public let name: String
    public let tool: String
    public let url: URL
    public let sizeBytes: Int64
    public let cost: Cost
    /// What is in there and what happens without it.
    public let explanation: String

    public var id: String { url.path }

    public init(
        name: String, tool: String, url: URL, sizeBytes: Int64,
        cost: Cost, explanation: String
    ) {
        self.name = name
        self.tool = tool
        self.url = url
        self.sizeBytes = sizeBytes
        self.cost = cost
        self.explanation = explanation
    }
}
