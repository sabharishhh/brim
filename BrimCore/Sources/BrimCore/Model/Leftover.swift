import Foundation

public struct Leftover: Sendable, Codable, Equatable, Identifiable {
    public enum Category: String, Sendable, Codable, Equatable {
        /// Owner was recorded present and is now gone, or a receipt exists for an absent product.
        case orphaned

        /// Residue that Brim cannot attribute to any installed app.
        case unclaimed
    }

    public let url: URL
    public let size: Int64
    public let category: Category
    public let potentialOwner: Identity?

    /// Why this is here — the sentence from the ownership search that decided
    /// the category. An orphan says which record named an owner that has
    /// gone; an unclaimed item says what was searched and came back empty.
    /// Never a bare assertion: the user is being asked to delete something.
    public let evidence: String

    /// Whether Brim can actually remove this, probed rather than assumed.
    ///
    /// A sandbox container is the case that forces this to exist: it is
    /// plainly visible and cannot be removed without Full Disk Access, and
    /// without a capability the attempt fails in a way that looks like a bug
    /// rather than a missing permission.
    public let capability: Capability

    /// When the item was last read. Used to *sort*, never to justify —
    /// an old access time is not evidence that software was uninstalled,
    /// only that nothing has looked at this lately.
    public let lastAccessed: Date?

    /// When Brim last saw the app this belongs to installed, where its
    /// snapshots recorded it.
    public var removedAt: Date?

    public var id: String { url.path }

    /// Whether Brim can take this away, itself or through its helper.
    ///
    /// Nine dead command links in a root-owned `/usr/local/bin` could not
    /// be ticked at all, because only `.ok` counted, though the helper
    /// exists for exactly that kind of leftover. The helper's own reading
    /// of what it will take decides, so nothing is ticked that it refuses.
    public var canBeRemovedByBrim: Bool {
        capability == .ok || (capability == .needsHelper && HelperScope.covers(url.path))
    }

    public init(
        url: URL,
        size: Int64,
        category: Category,
        potentialOwner: Identity? = nil,
        evidence: String = "",
        capability: Capability = .ok,
        lastAccessed: Date? = nil,
        removedAt: Date? = nil
    ) {
        self.url = url
        self.size = size
        self.category = category
        self.potentialOwner = potentialOwner
        self.evidence = evidence
        self.capability = capability
        self.lastAccessed = lastAccessed
        self.removedAt = removedAt
    }
}
