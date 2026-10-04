import BrimCore

/// Sizes of removed apps are independent of unclaimed or protected storage.
public struct HomeRemnantsSize: Equatable, Sendable {
    public let bytes: Int64
    public let isComplete: Bool
    private let reviewCount: Int

    public init(groups: [LeftoverGroup], unclaimed: Int = 0) {
        reviewCount = groups.isEmpty ? unclaimed : 0
        bytes = groups.reduce(0) { $0 + $1.totalBytes }
        isComplete = !groups.flatMap(\.items).contains { $0.sizeIsKnown == false }
    }

    public var figure: String {
        if reviewCount > 0 {
            return "\(reviewCount) to review"
        }
        if isComplete {
            return ByteText.short(bytes)
        }
        return bytes > 0 ? "At least " + ByteText.short(bytes) : "Size unavailable"
    }
}
