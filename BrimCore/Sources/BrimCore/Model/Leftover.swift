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
    public let sizeIsKnown: Bool?
    public let category: Category
    public let potentialOwner: Identity?

    /// Why this is here: the ownership search's sentence. An orphan names the
    /// record whose owner has gone; an unclaimed item says what was searched.
    public let evidence: String

    /// Whether Brim can remove this, probed rather than assumed, so a missing
    /// permission is reported as one rather than looking like a bug.
    public let capability: Capability

    /// When the item was last read. For sorting only: an old access time says
    /// nothing about whether the software was removed.
    public let lastAccessed: Date?

    /// When Brim last saw the app this belongs to installed, where its
    /// snapshots recorded it.
    public var removedAt: Date?

    /// The installed app that took the removed app's place, when that is
    /// proven. See `Replacement`. Information only: it selects nothing.
    public var replacedBy: Replacement?

    /// The developer's namespace, set on an unclaimed item only when nothing
    /// from that developer is installed. Then their leftovers are one group;
    /// while anything of theirs is installed, a namespace is not an application.
    public var vendor: String?

    public var id: String {
        url.path
    }

    /// Whether Brim can take this away, itself or through administrator
    /// cleanup, whose own rules decide, so nothing is ticked that it refuses.
    public var canBeRemovedByBrim: Bool {
        capability == .ok || (capability == .needsHelper
            && (RecoveryCopy.identifier(for: url.path) != nil || HelperScope.covers(url.path)))
    }

    public init(
        url: URL,
        size: Int64,
        category: Category,
        potentialOwner: Identity? = nil,
        evidence: String = "",
        capability: Capability = .ok,
        lastAccessed: Date? = nil,
        removedAt: Date? = nil,
        sizeIsKnown: Bool = true
    ) {
        self.url = url
        self.size = size
        self.sizeIsKnown = sizeIsKnown
        self.category = category
        self.potentialOwner = potentialOwner
        self.evidence = evidence
        self.capability = capability
        self.lastAccessed = lastAccessed
        self.removedAt = removedAt
    }
}
