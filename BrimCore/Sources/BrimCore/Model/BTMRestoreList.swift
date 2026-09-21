import Foundation

/// Everything that will be switched off, written down before it is.
///
/// A Background Task Management reset deregisters every login item and
/// background service on the Mac at once. Not one application's: all of
/// them. Afterwards the person has to find and re-enable each one, and
/// macOS offers no list of what was there before, so without this the
/// reset is a door that only opens one way.
///
/// So the list is captured first, persisted first, and shown first. The
/// executor refuses a `btmReset` step that has no persisted list against
/// its plan, which is T-3.8's acceptance criterion and the reason the
/// step kind is marked "partially reversible" rather than reversible.
public struct BTMRestoreList: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        /// What the person sees in Login Items.
        public let name: String
        /// Who signed it, when macOS recorded that.
        public let developer: String?
        /// The bundle this belongs to, for finding it again.
        public let bundleIdentifier: String?
        /// Where it is, when the store gave an absolute path.
        public let path: String?
        /// Login item, background service, and so on.
        public let type: String?
        /// Whether it was enabled at the time of capture. Re-enabling
        /// something the person had deliberately switched off would be its
        /// own small betrayal.
        public let wasEnabled: Bool

        public init(
            name: String, developer: String?, bundleIdentifier: String?,
            path: String?, type: String?, wasEnabled: Bool
        ) {
            self.name = name
            self.developer = developer
            self.bundleIdentifier = bundleIdentifier
            self.path = path
            self.type = type
            self.wasEnabled = wasEnabled
        }
    }

    public let capturedAt: Date
    public let entries: [Entry]

    /// Whether the capture saw the whole store.
    ///
    /// False when any account's store could not be read, which happens
    /// without Full Disk Access. A partial list is worse than none: it
    /// reads as complete and the person discovers what is missing only
    /// when something they depended on stops starting. Fail closed.
    public let isComplete: Bool

    /// Why the capture was incomplete, when it was.
    public let gap: String?

    public init(capturedAt: Date, entries: [Entry], isComplete: Bool, gap: String? = nil) {
        self.capturedAt = capturedAt
        self.entries = entries
        self.isComplete = isComplete
        self.gap = gap
    }

    /// Whether this list is good enough to reset against.
    ///
    /// An empty list is not: a Mac with no background items at all has
    /// nothing to reset, and an empty list far more often means the store
    /// was not read than that the store is empty.
    public var canSupportAReset: Bool {
        isComplete && !entries.isEmpty
    }

    /// What the person is told before they decide.
    public var summary: String {
        guard isComplete else {
            return "Brim could not read the whole background item list"
            + (gap.map { ", because \($0)" } ?? "")
            + ". Without a complete list there is no way to put things back, so the reset "
            + "is not offered."
        }
        if entries.isEmpty {
            return "There are no background items registered, so there is nothing to reset."
        }
        let enabled = entries.filter(\.wasEnabled).count
        return "\(entries.count) background \(entries.count == 1 ? "item" : "items") will be "
             + "deregistered, \(enabled) of \(entries.count) currently switched on. "
             + "Brim has written down what each one was so you can put them back."
    }
}
