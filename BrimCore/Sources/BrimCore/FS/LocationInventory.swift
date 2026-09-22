import Foundation

/// Every place software puts things, and how Brim would know it was this
/// application's.
///
/// A path on its own is not enough. The specification is explicit about
/// it: *each new location needs an evidence rule, not just a path, and a
/// location Brim can only name-match on is a Tier C location and must be
/// labelled as one.* A list of sixty-five directories with no rule per
/// directory is how a cleaning tool ends up deleting a folder because
/// somebody else's product happened to share a word with yours.
///
/// So the table carries the rule and the tier together. Adding a location
/// means deciding how a match there is proved, which is the part that
/// takes the judgement and the part that keeps the claim honest.
public struct LocationInventory: Sendable {

    /// How something in a location is shown to belong to an application.
    public enum Rule: Sendable, Equatable {
        /// A file or folder named exactly the bundle identifier.
        /// `~/Library/Application Support/com.example.app`.
        case bundleIdentifier
        /// A file named `<bundleIdentifier>.<extension>`.
        /// `~/Library/Preferences/com.example.app.plist`.
        case bundleIdentifierFile(String)
        /// A file whose name begins with the bundle identifier. Catches
        /// `com.example.app.savedState` and the ByHost variants, where a
        /// hardware identifier follows.
        case bundleIdentifierPrefix
        /// A file or folder named exactly the application's name.
        case applicationName
        /// A file or folder named the application's name in lower case.
        ///
        /// The convention outside `~/Library` is a lowercased name:
        /// `~/.local/share/claude`, `~/.config/gh`. Most Macs have a
        /// case-insensitive volume and would match these by accident, which
        /// is worse than not matching them, because the accident stops on a
        /// case-sensitive volume and the developers most likely to have one
        /// are the people whose `~/.cache` is measured in gigabytes.
        case applicationNameLowercased
        /// A bundle in this folder whose own `Info.plist` declares the
        /// identifier. The only way to attribute an audio plug-in, whose
        /// file name says nothing at all.
        case identifierInsideBundle
    }

    public struct Location: Sendable, Equatable {
        public let domain: FileSystemRoot.Domain
        public let rule: Rule
        /// What a person would call the thing found here.
        public let describes: String
        /// How sure this makes Brim. Derived from the rule and then
        /// floored by the domain: a location that can only ever be
        /// name-matched is Tier C however it is written down here.
        public let tier: EvidenceTier
        public let sentence: String

        public init(
            domain: FileSystemRoot.Domain, rule: Rule,
            describes: String, sentence: String
        ) {
            self.domain = domain
            self.rule = rule
            self.describes = describes
            self.sentence = sentence
            self.tier = Self.tier(for: rule, in: domain)
        }

        /// The rule decides the tier, and the domain can only weaken it.
        ///
        /// A bundle identifier is a reverse-DNS name nobody else uses, so
        /// a path component equal to one is strong evidence. A human name
        /// is not: two products called "Studio" are ordinary, which is
        /// why a name match is never selected by default.
        static func tier(for rule: Rule, in domain: FileSystemRoot.Domain) -> EvidenceTier {
            if FileSystemRoot.onlyNameMatchable(domain) { return .C }
            switch rule {
            case .bundleIdentifier, .bundleIdentifierFile, .bundleIdentifierPrefix,
                 .identifierInsideBundle:
                return .B
            case .applicationName, .applicationNameLowercased:
                return .C
            }
        }
    }

    /// The domains a sweep for leftovers should walk.
    ///
    /// Derived from the same table the uninstall path uses, so the two
    /// questions cannot drift apart again. They already had: removing an
    /// application by name looked in sixty places while sweeping for what
    /// software had left behind looked in eight, so the whole system
    /// domain, every installer receipt and every command line tool was
    /// invisible to the question they were most relevant to.
    ///
    /// Leaves out what a sweep cannot reason about: the folders
    /// applications themselves live in, other volumes, other accounts,
    /// and the system's own temporary directory.
    public static var sweepDomains: [FileSystemRoot.Domain] {
        var seen: Set<FileSystemRoot.Domain> = []
        var result: [FileSystemRoot.Domain] = []
        for location in standard.locations where !notWorthSweeping.contains(location.domain) {
            if seen.insert(location.domain).inserted { result.append(location.domain) }
        }
        return result
    }

    static let notWorthSweeping: Set<FileSystemRoot.Domain> = [
        .applications, .userApplications, .volumes, .users, .tempDirs,
        // Fonts have no owning application, and a sweep of them is a list
        // of every typeface somebody has ever installed.
        .userFonts, .systemFonts,
        // Per-boot scratch space. Every running process writes here and
        // macOS empties it, so a sweep of it is a thousand rows of
        // transient files that will be gone by morning. It stays in the
        // inventory because a folder there named after a bundle is a
        // genuine part of that application's footprint; it is only
        // useless as an answer to "what has been left behind".
        .darwinUserTemp,
        // Held back from the sweep rather than judged worthless. An
        // orphaned recent-documents record is a real leftover, but the
        // directory holds about fifty of Apple's own alongside the third
        // party ones, and the leftovers list is already long enough to be
        // the thing people complain about. It joins the sweep when there is
        // something to tell Apple's records apart from everybody else's.
        .userRecentDocuments,
        // Held back for the same reason and a sharper one. These folders
        // belong overwhelmingly to command line tools that are very much
        // still installed: `~/.config/git`, `~/.config/gh`, `~/.cache/uv`.
        // A tool has no application bundle, so the sweep's test for whether
        // something is still owned cannot see it, and every one of them
        // would be offered as a leftover. The uninstall path searches here
        // because it starts from an application that is genuinely going;
        // the sweep cannot until it can recognise a command line tool.
        .userDotConfig, .userDotCache, .userDotLocalShare,
        .userDotLocalState, .userDotLocalBin,
    ]

    public let locations: [Location]

    public init(locations: [Location]) {
        self.locations = locations
    }

    /// The inventory Brim actually uses.
    ///
    /// Grew from nineteen domains, which was less than AppCleaner reaches.
    /// The ones that matter most are the invisible ones: `ByHost`
    /// preferences are a second copy of an application's settings that a
    /// scan of `Preferences` walks straight past, the Darwin per-user
    /// folders hold caches nothing else enumerates, and an audio plug-in
    /// keeps its identifier inside the bundle so no path match can ever
    /// see it.
    public static let standard = LocationInventory(locations: [
        // Settings and state, keyed by identifier.
        Location(domain: .userPreferences, rule: .bundleIdentifierPrefix,
                 describes: "preferences",
                 sentence: "Preferences keyed to the bundle identifier."),
        Location(domain: .userPreferencesByHost, rule: .bundleIdentifierPrefix,
                 describes: "per-machine preferences",
                 sentence: "Per-machine preferences keyed to the bundle identifier. These are "
                         + "a second copy of the settings, and a scan of Preferences alone "
                         + "misses them."),
        Location(domain: .systemPreferences, rule: .bundleIdentifierPrefix,
                 describes: "preferences for every user",
                 sentence: "Preferences set for every user on this Mac, keyed to the bundle "
                         + "identifier."),
        // Prefixed rather than exact, and the difference is an updater.
        // An application installed by any route can switch to updating
        // itself afterwards, and Squirrel leaves `<identifier>.ShipIt` in
        // Caches. An exact rule walks straight past it, and three of the
        // six applications measured on this Mac were carrying one. The same
        // shape catches a helper that keeps its own folder under the
        // application's identifier, which is the ordinary case for anything
        // shipping an XPC service.
        //
        // The prefix is the identifier and a dot, so `com.example.app` does
        // not reach `com.example.applet`, and it is still an identifier
        // match, so it is still Tier B.
        Location(domain: .userApplicationSupport, rule: .bundleIdentifierPrefix,
                 describes: "supporting files",
                 sentence: "Application Support keyed to the bundle identifier."),
        Location(domain: .systemApplicationSupport, rule: .bundleIdentifierPrefix,
                 describes: "supporting files for every user",
                 sentence: "Application Support for every user, keyed to the bundle identifier."),
        Location(domain: .userCaches, rule: .bundleIdentifierPrefix,
                 describes: "caches",
                 sentence: "A cache folder keyed to the bundle identifier."),
        Location(domain: .systemCaches, rule: .bundleIdentifierPrefix,
                 describes: "caches for every user",
                 sentence: "A cache folder for every user, keyed to the bundle identifier."),
        // Caches and Logs had an identifier rule and no name rule at all,
        // so a folder an application named after itself was not so much
        // missed as never looked for. Antigravity keeps 7 MB in
        // `Caches/Antigravity` and Claude 2.8 MB in `Logs/Claude`, and
        // neither appeared in its own uninstall. A name is a name, so these
        // are Tier C and Brim will not tick them for anybody.
        Location(domain: .userCaches, rule: .applicationName,
                 describes: "caches",
                 sentence: "A cache folder named after the application rather than its "
                         + "identifier."),
        Location(domain: .userLogs, rule: .applicationName,
                 describes: "logs",
                 sentence: "A log folder named after the application rather than its "
                         + "identifier."),
        Location(domain: .userApplicationSupport, rule: .applicationName,
                 describes: "supporting files",
                 sentence: "Application Support named after the application rather than its "
                         + "identifier."),
        Location(domain: .userSavedApplicationState, rule: .bundleIdentifierPrefix,
                 describes: "saved windows",
                 sentence: "The windows and documents macOS reopens for this application."),
        // Keyed exactly on the bundle identifier, and missing from all six
        // footprints measured on this Mac because no location named the
        // directory it lives in.
        //
        // This one is a list of the person's own files and it still goes.
        // The record belongs to the application; the documents it names
        // belong to the person and outlive it. Delete the record, never
        // what it points at. `RecordedPathTests` went in before this row
        // did, which is the only order in which that guard means anything.
        Location(domain: .userRecentDocuments, rule: .bundleIdentifierFile("sfl4"),
                 describes: "recently opened documents",
                 sentence: "The list macOS keeps of documents this application opened. The "
                         + "list goes; the documents stay where they are."),
        Location(domain: .userHTTPStorages, rule: .bundleIdentifierPrefix,
                 describes: "stored web data",
                 sentence: "Cookies and web storage macOS keeps for this application."),
        Location(domain: .userCookies, rule: .bundleIdentifierPrefix,
                 describes: "cookies",
                 sentence: "Cookies keyed to the bundle identifier."),
        Location(domain: .userApplicationScripts, rule: .bundleIdentifier,
                 describes: "automation scripts",
                 sentence: "The folder macOS gives a sandboxed application for its scripts."),
        Location(domain: .userAutosaveInformation, rule: .bundleIdentifierPrefix,
                 describes: "autosaved documents",
                 sentence: "Documents this application autosaved but never closed."),
        Location(domain: .userLogs, rule: .bundleIdentifier,
                 describes: "logs",
                 sentence: "A log folder keyed to the bundle identifier."),
        Location(domain: .systemLogs, rule: .bundleIdentifier,
                 describes: "logs for every user",
                 sentence: "A log folder for every user, keyed to the bundle identifier."),
        Location(domain: .userDiagnosticReports, rule: .applicationName,
                 describes: "crash reports",
                 sentence: "Crash reports named after this application. These accumulate for "
                         + "years and nothing removes them."),
        Location(domain: .systemDiagnosticReports, rule: .applicationName,
                 describes: "crash reports",
                 sentence: "Crash reports named after this application."),

        // The plug-in folders, where the identifier is inside the bundle.
        Location(domain: .userInternetPlugIns, rule: .identifierInsideBundle,
                 describes: "an Internet plug-in",
                 sentence: "An Internet plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemInternetPlugIns, rule: .identifierInsideBundle,
                 describes: "an Internet plug-in",
                 sentence: "An Internet plug-in whose own Info.plist declares this identifier."),
        Location(domain: .userPreferencePanes, rule: .identifierInsideBundle,
                 describes: "a preference pane",
                 sentence: "A preference pane whose own Info.plist declares this identifier."),
        Location(domain: .systemPreferencePanes, rule: .identifierInsideBundle,
                 describes: "a preference pane",
                 sentence: "A preference pane whose own Info.plist declares this identifier."),
        Location(domain: .userServices, rule: .identifierInsideBundle,
                 describes: "a Services menu item",
                 sentence: "A Services menu item whose own Info.plist declares this identifier."),
        Location(domain: .systemServices, rule: .identifierInsideBundle,
                 describes: "a Services menu item",
                 sentence: "A Services menu item whose own Info.plist declares this identifier."),
        Location(domain: .userQuickLook, rule: .identifierInsideBundle,
                 describes: "a Quick Look generator",
                 sentence: "A Quick Look generator whose own Info.plist declares this identifier."),
        Location(domain: .systemQuickLook, rule: .identifierInsideBundle,
                 describes: "a Quick Look generator",
                 sentence: "A Quick Look generator whose own Info.plist declares this identifier."),
        Location(domain: .userSpotlight, rule: .identifierInsideBundle,
                 describes: "a Spotlight importer",
                 sentence: "A Spotlight importer whose own Info.plist declares this identifier."),
        Location(domain: .systemSpotlight, rule: .identifierInsideBundle,
                 describes: "a Spotlight importer",
                 sentence: "A Spotlight importer whose own Info.plist declares this identifier."),
        Location(domain: .userAutomator, rule: .identifierInsideBundle,
                 describes: "an Automator action",
                 sentence: "An Automator action whose own Info.plist declares this identifier."),
        Location(domain: .systemAutomator, rule: .identifierInsideBundle,
                 describes: "an Automator action",
                 sentence: "An Automator action whose own Info.plist declares this identifier."),
        Location(domain: .userColorPickers, rule: .identifierInsideBundle,
                 describes: "a colour picker",
                 sentence: "A colour picker whose own Info.plist declares this identifier."),
        Location(domain: .systemColorPickers, rule: .identifierInsideBundle,
                 describes: "a colour picker",
                 sentence: "A colour picker whose own Info.plist declares this identifier."),
        Location(domain: .userScreenSavers, rule: .identifierInsideBundle,
                 describes: "a screen saver",
                 sentence: "A screen saver whose own Info.plist declares this identifier."),
        Location(domain: .systemScreenSavers, rule: .identifierInsideBundle,
                 describes: "a screen saver",
                 sentence: "A screen saver whose own Info.plist declares this identifier."),
        Location(domain: .userWidgets, rule: .identifierInsideBundle,
                 describes: "a widget",
                 sentence: "A widget whose own Info.plist declares this identifier."),
        Location(domain: .userAudioComponents, rule: .identifierInsideBundle,
                 describes: "an Audio Unit",
                 sentence: "An Audio Unit whose own Info.plist declares this identifier. Audio "
                         + "plug-ins are invisible to any scan that only reads path names."),
        Location(domain: .systemAudioComponents, rule: .identifierInsideBundle,
                 describes: "an Audio Unit",
                 sentence: "An Audio Unit whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioVST, rule: .identifierInsideBundle,
                 describes: "a VST plug-in",
                 sentence: "A VST plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioVST3, rule: .identifierInsideBundle,
                 describes: "a VST3 plug-in",
                 sentence: "A VST3 plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioCLAP, rule: .identifierInsideBundle,
                 describes: "a CLAP plug-in",
                 sentence: "A CLAP plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioHAL, rule: .identifierInsideBundle,
                 describes: "an audio device plug-in",
                 sentence: "An audio device plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioMAS, rule: .identifierInsideBundle,
                 describes: "an audio plug-in",
                 sentence: "An audio plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemAudioAvid, rule: .identifierInsideBundle,
                 describes: "an Avid audio plug-in",
                 sentence: "An Avid plug-in whose own Info.plist declares this identifier."),
        Location(domain: .systemExtensionsFolder, rule: .identifierInsideBundle,
                 describes: "a kernel extension",
                 sentence: "A kernel extension whose own Info.plist declares this identifier."),
        Location(domain: .startupItems, rule: .applicationName,
                 describes: "a startup item",
                 sentence: "A startup item named after this application."),

        // Where a command line tool lands, and the only rule available
        // there is its name.
        Location(domain: .usrLocalBin, rule: .applicationName,
                 describes: "a command line tool",
                 sentence: "A command line tool with this name. A tool has no bundle and no "
                         + "identifier, so the only thing linking it to this application is "
                         + "that they share a name."),
        Location(domain: .usrLocalSbin, rule: .applicationName,
                 describes: "a command line tool",
                 sentence: "A command line tool with this name, matched on the name alone."),
        Location(domain: .usrLocalOpt, rule: .applicationName,
                 describes: "supporting files for a command line tool",
                 sentence: "A folder with this name, matched on the name alone."),
        Location(domain: .usrLocalEtc, rule: .applicationName,
                 describes: "configuration for a command line tool",
                 sentence: "Configuration with this name, matched on the name alone."),
        Location(domain: .usrLocalShare, rule: .applicationName,
                 describes: "shared data for a command line tool",
                 sentence: "Shared data with this name, matched on the name alone."),
        Location(domain: .usrLocalVar, rule: .applicationName,
                 describes: "state for a command line tool",
                 sentence: "State with this name, matched on the name alone."),

        // Shared and per-boot folders. Name matching only, and labelled.
        Location(domain: .sharedApplicationSupport, rule: .bundleIdentifier,
                 describes: "supporting files in the shared folder",
                 sentence: "Something in the shared folder keyed to the bundle identifier. "
                         + "Anyone on this Mac can put things here, so it is shown rather "
                         + "than selected."),
        Location(domain: .sharedUser, rule: .applicationName,
                 describes: "files in the shared folder",
                 sentence: "Something in the shared folder with this name. Anyone on this Mac "
                         + "can put things here."),
        Location(domain: .darwinUserCache, rule: .bundleIdentifier,
                 describes: "a per-boot cache",
                 sentence: "A cache in the per-user folder macOS makes fresh each boot. "
                         + "Nothing else enumerates these."),
        // Outside `~/Library` entirely, which is where cross-platform
        // software actually keeps its data. A tool written for Linux first
        // looks in `~/.config` and `~/.local/share` because that is where
        // its other builds look, and rewriting that for macOS is work
        // almost nobody does. Nothing in Brim read `$HOME` directly, so
        // Claude's 189 MB under `~/.local/share/claude` was invisible to
        // every evidence source at once.
        //
        // Lower case on purpose. The convention here is a lowercased name,
        // and a case-insensitive volume would paper over the difference
        // until somebody ran Brim on a case-sensitive one.
        Location(domain: .userDotConfig, rule: .applicationNameLowercased,
                 describes: "settings",
                 sentence: "Settings kept the way cross-platform software keeps them, outside "
                         + "the Library folder. Matched on the name alone."),
        Location(domain: .userDotCache, rule: .applicationNameLowercased,
                 describes: "caches",
                 sentence: "A cache kept outside the Library folder. Matched on the name "
                         + "alone."),
        Location(domain: .userDotLocalShare, rule: .applicationNameLowercased,
                 describes: "stored data",
                 sentence: "Data kept outside the Library folder, which for this kind of "
                         + "software is usually the bulk of it. Matched on the name alone."),
        Location(domain: .userDotLocalState, rule: .applicationNameLowercased,
                 describes: "saved state",
                 sentence: "State kept outside the Library folder. Matched on the name alone."),
        Location(domain: .userDotLocalBin, rule: .applicationNameLowercased,
                 describes: "command line tools",
                 sentence: "A command installed outside the Library folder. Matched on the "
                         + "name alone."),
        Location(domain: .darwinUserTemp, rule: .bundleIdentifier,
                 describes: "per-boot temporary files",
                 sentence: "Temporary files in the per-user folder macOS makes fresh each boot."),
    ])
}
