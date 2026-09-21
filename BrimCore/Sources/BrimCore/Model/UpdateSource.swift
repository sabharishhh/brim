import Foundation

/// How an application gets its next version, if it has a way at all.
///
/// The Updates section listed launchd updater agents, which is a real
/// finding and a small one: it answers "who is checking for updates in the
/// background" and says nothing about the application in front of you.
/// T-5.8 asks the more useful question, which is whether each application
/// has any route to a new version, and names the route.
///
/// Every answer here is read from the disk. A Sparkle feed is a string in
/// an `Info.plist`, an App Store purchase is a receipt file inside the
/// bundle, a Homebrew cask is a directory in the Caskroom. Nothing is
/// fetched, nothing is looked up, and the view renders the same with the
/// network off. The specification is firm about this and it is right:
/// software that phones home while you are looking at a list is software
/// you cannot audit.
public enum UpdateSource: Equatable, Sendable, Codable {
    /// Bought or installed from the App Store, which updates it.
    case appStore
    /// Ships Sparkle and declares a feed. The overwhelmingly common way
    /// a Mac application outside the store updates itself.
    case sparkle(feed: String)
    /// Installed by Homebrew, so `brew upgrade` is the route and
    /// `brew uninstall` is how it should be removed.
    case homebrewCask(name: String)
    /// A vendor's own background updater is installed for it.
    case vendorUpdater(vendor: String)

    /// Said the way a person would ask about it.
    public var sentence: String {
        switch self {
        case .appStore:
            return "The App Store updates this."
        case .sparkle(let feed):
            return "This checks \(UpdateSource.host(of: feed)) for new versions by itself."
        case .homebrewCask(let name):
            return "Homebrew installed this as the cask \(name), so brew upgrade updates it."
        case .vendorUpdater(let vendor):
            return "\(vendor) installed a background updater that keeps this current."
        }
    }

    /// Where a row is sorted and grouped. An application with several
    /// routes is normal: a Homebrew cask that also ships Sparkle has two.
    public var rank: Int {
        switch self {
        case .appStore: return 0
        case .homebrewCask: return 1
        case .sparkle: return 2
        case .vendorUpdater: return 3
        }
    }

    /// Just the host, because the whole feed URL in a row is noise and
    /// the domain is the part that says who is being trusted.
    static func host(of feed: String) -> String {
        URL(string: feed)?.host ?? feed
    }
}

/// One application and every route it has to a new version.
public struct UpdateCoverage: Equatable, Sendable, Codable, Identifiable {
    public let application: InstalledApplication
    public let sources: [UpdateSource]

    public var id: String { application.id }

    public init(application: InstalledApplication, sources: [UpdateSource]) {
        self.application = application
        self.sources = sources.sorted { $0.rank < $1.rank }
    }

    /// The finding. Software with no route to a new version is software
    /// that will sit at whatever version it is at until somebody notices,
    /// which for anything that opens a file off the internet is the whole
    /// problem.
    public var hasNoWayToUpdate: Bool {
        sources.isEmpty && !application.isSystemProtected
    }

    /// Whether Homebrew should be asked to remove this rather than Brim
    /// deleting the files underneath it.
    public var homebrewCask: String? {
        for source in sources {
            if case .homebrewCask(let name) = source { return name }
        }
        return nil
    }

    public var sentence: String {
        guard !sources.isEmpty else {
            return application.isSystemProtected
                ? "macOS updates this."
                : "Nothing updates this. It stays at \(application.version ?? "this version") "
                + "until you replace it by hand."
        }
        return sources.map(\.sentence).joined(separator: " ")
    }
}

/// What the Updates section knows, all of it read locally.
public struct UpdateReport: Equatable, Sendable, Codable {
    public let coverage: [UpdateCoverage]
    /// Background updaters still running, including ones whose software
    /// has gone. The old Updates section, kept because it answers a
    /// different question and a useful one.
    public let agents: [UpdaterAgent]
    /// Whether Homebrew is on this Mac at all, so the absence of cask
    /// matches can be explained rather than looking like a gap.
    public let homebrewPresent: Bool

    public init(
        coverage: [UpdateCoverage], agents: [UpdaterAgent], homebrewPresent: Bool
    ) {
        self.coverage = coverage
        self.agents = agents
        self.homebrewPresent = homebrewPresent
    }

    public var withoutAnyUpdateSource: [UpdateCoverage] {
        coverage.filter(\.hasNoWayToUpdate).sorted {
            $0.application.name < $1.application.name
        }
    }

    /// Updaters checking for software that is not here any more.
    public var orphanedAgents: [UpdaterAgent] {
        agents.filter { !$0.productIsInstalled }
    }

    public var summary: String {
        let stranded = withoutAnyUpdateSource.count
        let orphaned = orphanedAgents.count
        var parts: [String] = []
        if stranded > 0 {
            parts.append("\(stranded) \(stranded == 1 ? "application has" : "applications have") "
                       + "no way to update \(stranded == 1 ? "itself" : "themselves")")
        }
        if orphaned > 0 {
            parts.append("\(orphaned) background \(orphaned == 1 ? "updater is" : "updaters are") "
                       + "still checking for software that is gone")
        }
        guard !parts.isEmpty else {
            return "Everything here has a way to get its next version."
        }
        return parts.joined(separator: ", and ") + "."
    }
}
