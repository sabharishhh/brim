import Foundation

/// What a running process actually is, worked out from where it lives.
///
/// The energy list read `contactsd`, `suggestd`, `duetexpertd`,
/// `mediaanalysisd` and `spotlightknowledged.updater` straight off the
/// executable path and printed them. Those are the five largest consumers on
/// this Mac and not one of them tells a person anything. Worse, they sat in
/// the same undifferentiated list as Claude and ChatGPT, so the list read as
/// though a person could act on all of it, when half of it is macOS running
/// itself and is nobody's to switch off.
///
/// Classification is derived from the path, which is a fact about the file
/// rather than a guess: a bundle under `/Applications` is an application, a
/// binary under `/System/Library` belongs to macOS, one under
/// `/opt/homebrew` or `/usr/local` was installed by a package manager.
/// Nothing here pattern-matches a *name*.
///
/// The one table is the plain-English names for Apple's own background
/// services. There is no API that returns "contactsd syncs your contacts",
/// and inventing a description from the binary's name would be exactly the
/// confident nonsense this product exists to avoid. So a name is either one
/// Apple documents and a person can verify, or it is not claimed at all: an
/// unrecognised system daemon says it belongs to macOS, which is true and
/// derived, and says nothing further.
public struct RunningProcessIdentity: Sendable, Equatable, Hashable {

    /// What kind of thing this is, which decides how it is grouped, what
    /// icon it gets, and whether a person can do anything about it.
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        /// An application with a bundle, which a person launched.
        case application
        /// Part of macOS. Not a person's to stop, and grouped away from the
        /// things that are.
        case systemService
        /// A helper, agent or extension shipped inside somebody's app.
        case helper
        /// A binary a package manager or the person put on the path.
        case commandLineTool
        /// Somewhere else on the disk. Said plainly rather than guessed at.
        case other

        /// Whether the person can reasonably act on this.
        ///
        /// The point of the distinction: a list that mixes "quit Figma" with
        /// "macOS is indexing Spotlight" invites somebody to try to stop the
        /// second one.
        public var isActionable: Bool {
            switch self {
            case .application, .commandLineTool: return true
            case .systemService, .helper, .other: return false
            }
        }

        /// An SF Symbol for rows with no icon of their own.
        public var symbolName: String {
            switch self {
            case .application: return "app.dashed"
            case .systemService: return "gearshape.2"
            case .helper: return "puzzlepiece.extension"
            case .commandLineTool: return "terminal"
            case .other: return "questionmark.square.dashed"
            }
        }

        /// A short label for the row.
        public var label: String {
            switch self {
            case .application: return "App"
            case .systemService: return "macOS"
            case .helper: return "Helper"
            case .commandLineTool: return "Command line"
            case .other: return "Other"
            }
        }
    }

    /// What to call it on screen.
    public let displayName: String
    /// The bundle it belongs to, when it belongs to one. Drives the icon.
    public let bundlePath: String?
    /// The binary that was running.
    public let executablePath: String
    public let kind: Kind
    /// What this does, when that is something Brim can state rather than
    /// guess. Nil is a normal answer and means the row says nothing extra.
    public let explanation: String?

    public init(
        displayName: String, bundlePath: String?, executablePath: String,
        kind: Kind, explanation: String?
    ) {
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.kind = kind
        self.explanation = explanation
    }

    /// The key several processes of one product collapse under.
    public var groupKey: String { bundlePath ?? executablePath }

    // MARK: - Deriving it

    public static func of(bundlePath: String?, executablePath: String) -> RunningProcessIdentity {
        let binary = URL(fileURLWithPath: executablePath).lastPathComponent

        // A bundle is the strongest signal there is, and the name in it is
        // the one the developer chose.
        if let bundlePath {
            let name = URL(fileURLWithPath: bundlePath)
                .deletingPathExtension().lastPathComponent

            // `/System/Applications` is where every app Apple ships now
            // lives: Music, Safari, Mail, Notes, Photos. Treating anything
            // under `/System/` as a service filed all of them as macOS
            // running itself, badged them as nobody's to stop, and sorted
            // them into the half of the panel headed "most of this finishes
            // on its own". Music playing an album is a person's to quit.
            //
            // `/System/Library` and `/usr/libexec` are the services.
            let isService = bundlePath.hasPrefix("/System/Library/")
                || bundlePath.hasPrefix("/usr/libexec/")
            let kind: Kind = isService ? .systemService : .application
            return RunningProcessIdentity(
                displayName: name, bundlePath: bundlePath, executablePath: executablePath,
                kind: kind, explanation: kind == .systemService ? Self.macOSExplanation : nil
            )
        }

        // Apple's own background services, which are the ones that dominate
        // the list and the ones whose names mean least.
        if let known = appleService(named: binary) {
            return RunningProcessIdentity(
                displayName: known.name, bundlePath: nil, executablePath: executablePath,
                kind: .systemService, explanation: known.explanation
            )
        }

        if executablePath.hasPrefix("/System/") || executablePath.hasPrefix("/usr/libexec/")
            || executablePath.hasPrefix("/usr/sbin/") || executablePath.hasPrefix("/sbin/") {
            return RunningProcessIdentity(
                displayName: binary, bundlePath: nil, executablePath: executablePath,
                kind: .systemService, explanation: Self.macOSExplanation
            )
        }

        // Inside somebody's bundle, but not the bundle itself: a helper, an
        // XPC service, an extension.
        if let owner = EnclosingBundle.name(of: URL(fileURLWithPath: executablePath)) {
            return RunningProcessIdentity(
                displayName: binary, bundlePath: nil, executablePath: executablePath,
                kind: .helper, explanation: "Part of \(owner)."
            )
        }

        if executablePath.hasPrefix("/opt/homebrew/") || executablePath.hasPrefix("/usr/local/")
            || executablePath.hasPrefix("/opt/local/") {
            return RunningProcessIdentity(
                displayName: binary, bundlePath: nil, executablePath: executablePath,
                kind: .commandLineTool,
                explanation: "A command line tool, installed outside the App Store."
            )
        }

        return RunningProcessIdentity(
            displayName: binary, bundlePath: nil, executablePath: executablePath,
            kind: .other, explanation: nil
        )
    }

    private static let macOSExplanation = "Part of macOS, running on its own schedule."

    /// Apple's background services, in words a person can check.
    ///
    /// Deliberately small and deliberately literal. Each of these is a
    /// documented part of macOS whose job can be stated without inference,
    /// and the list covers what actually shows up at the top of an energy
    /// reading. A daemon that is not here is still identified as part of
    /// macOS, which is derived from its path; it simply gets no sentence,
    /// because Brim does not have one to give.
    /// Never the name of an application.
    ///
    /// The first version of this called `contactsd` "Contacts", and the
    /// person reading it had opened the Contacts app exactly once, to see
    /// what a native Mac app looked like. The panel appeared to be telling
    /// them an app they never use had cost 4.2% of a charge. It was not:
    /// `contactsd` holds the contacts database and answers every app that
    /// reads from it, plus iCloud sync, and runs whether or not the Contacts
    /// app has ever been opened.
    ///
    /// Replacing an opaque name with a misleading one is worse than leaving
    /// it opaque, so every name here describes the *service* and none of
    /// them is an app's name. Where the distinction matters, the explanation
    /// says out loud that the work is being done for something else.
    static func appleService(named binary: String) -> (name: String, explanation: String)? {
        // Matched on the whole binary name, not a prefix, so a third-party
        // binary that happens to start with the same letters is not claimed.
        switch binary {
        case "contactsd":
            return ("Contacts database",
                    "Holds your contacts and answers any app that reads them, including Mail and "
                    + "Messages. It also syncs them with iCloud. This runs whether or not you use "
                    + "the Contacts app.")
        case "suggestd":
            return ("Siri suggestion learning",
                    "Learns from what you do so Siri and Spotlight can suggest things. Turn it "
                    + "down in Siri and Spotlight settings.")
        case "duetexpertd":
            return ("Siri prediction",
                    "Works out what you are likely to want next, for Siri, Shortcuts and widgets.")
        case "mediaanalysisd":
            return ("Media analysis",
                    "Scans images and video for faces, scenes and text, on behalf of Photos, "
                    + "Quick Look and Spotlight. Usually runs when the Mac is idle and then stops.")
        case "photoanalysisd":
            return ("Photo library analysis",
                    "Builds the People album and the search index for your photo library. Runs "
                    + "once through a new library and then goes quiet.")
        case "spotlightknowledged", "spotlightknowledged.updater":
            return ("Spotlight learning",
                    "Keeps Spotlight's suggestions in step with what you search for.")
        case "mds", "mds_stores", "mdworker", "mdworker_shared":
            return ("Spotlight indexing",
                    "Reads new and changed files so Spotlight can find them. Heavy right after a "
                    + "large copy or a restore.")
        case "WindowServer":
            return ("Screen drawing",
                    "Draws everything on screen for every app. Heavy use usually means animation, "
                    + "a high refresh rate, or a lot of pixels.")
        case "WindowManager":
            return ("Window arrangement",
                    "Arranges windows, and runs Stage Manager when it is switched on.")
        case "kernel_task":
            return ("macOS core",
                    "The kernel. It also deliberately takes on work to keep the Mac cool.")
        case "backupd":
            return ("Time Machine backup", "A backup is running.")
        case "cloudd", "bird":
            return ("iCloud transfer",
                    "Moving files and data between this Mac and iCloud for whichever apps store "
                    + "things there.")
        case "syncdefaultsd":
            return ("iCloud settings sync",
                    "Syncs preferences and account settings through iCloud.")
        case "appleaccountd", "akd":
            return ("Apple Account sign-in",
                    "Keeps this Mac signed in to your Apple Account.")
        case "knowledge-agent":
            return ("Usage history",
                    "Records what you use. Screen Time and Siri read it.")
        case "corespotlightd":
            return ("In-app search index",
                    "Indexes content apps have handed to Spotlight so you can search inside them.")
        case "powerd":
            return ("Power management",
                    "Decides when the Mac sleeps and how it draws power.")
        case "coreaudiod":
            return ("Audio engine",
                    "Runs audio in and out for every app making or recording sound.")
        case "bluetoothd":
            return ("Bluetooth", "Runs Bluetooth connections to your accessories.")
        case "sharingd":
            return ("Continuity", "AirDrop, Handoff and Universal Clipboard.")
        case "trustd":
            return ("Certificate checking",
                    "Checks the certificates behind secure connections, for every app that makes "
                    + "one.")
        case "nsurlsessiond":
            return ("Background transfers",
                    "Carries downloads and uploads on behalf of other apps, so the work shows up "
                    + "here rather than against the app that asked for it.")
        case "assistantd":
            return ("Siri request handling",
                    "Answers requests made to Siri, by voice or by type.")
        case "siriactionsd":
            return ("Shortcuts and Siri actions",
                    "Runs Shortcuts and the actions apps offer to Siri.")
        case "generativeexperiencesd":
            return ("Apple Intelligence",
                    "On-device models behind Writing Tools, summaries and Siri.")
        case "sysmond":
            return ("System statistics",
                    "Collects the figures Activity Monitor and Brim read.")
        case "distnoted", "notifyd":
            return ("Inter-app messaging",
                    "Passes notifications between running programs.")
        default:
            return nil
        }
    }
}
