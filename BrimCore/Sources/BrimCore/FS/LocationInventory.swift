import Foundation

/// Every place software puts things, and how Brim would know a match there
/// is this application's. Each location carries its rule and tier together:
/// adding a path means deciding how a match there is proved, or a folder
/// gets deleted for sharing a word with an app.
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
        /// A suffix separated from the identifier, such as
        /// `com.example.editor-helper`. Name-derived and therefore Tier C.
        case bundleIdentifierDelimitedPrefix(String)
        /// Anything named inside the bundle identifier in the per-user folders,
        /// `<identifier>.<anything>` or `.<identifier>.<anything>`: how `mkdtemp` and
        /// Chromium name scratch folders that are often never removed.
        case temporaryDirectory
        /// A folder a system service keeps for the application, named
        /// `<service>+<identifier>`, such as WebKit's three per app that shows a web
        /// view.
        case clientOfService
        /// A group explicitly declared by the bundle, or an unverified
        /// `group.<bundle id>` name when no declaration could be read.
        case groupContainer
        /// A file or folder named exactly the application's name.
        case applicationName
        /// The application's name in lower case, the convention outside `~/Library`
        /// (`~/.local/share/claude`). Matched exactly, because a case-insensitive
        /// volume would match by accident and stop on a case-sensitive one.
        case applicationNameLowercased
        /// A name followed by a clear separator, such as
        /// `Claude - ask.workflow` or `Claude-3p`.
        case applicationNameDelimitedPrefix(String)
        /// A bundle in this folder whose own `Info.plist` declares the identifier:
        /// the only way to attribute an audio plug-in.
        case identifierInsideBundle
        /// A dot folder in the home folder: one the bundle declares as its
        /// own, or `.<name>` and `.<name>-<anything>` in lower case, which
        /// is how Electron editors name theirs (`.antigravity-ide`).
        case homeDotFolder
        /// A crash or resource report named for one of the application's processes
        /// and a date: `Purge-2026-09-29-090414.ips`.
        case diagnosticReport
    }

    public struct Location: Sendable, Equatable {
        public let domain: FileSystemRoot.Domain
        public let rule: Rule
        /// What a person would call the thing found here.
        public let describes: String
        /// How sure this makes Brim: derived from the rule, floored by the domain.
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
            tier = Self.tier(for: rule, in: domain)
        }

        /// The rule decides the tier and the domain can only weaken it. A bundle
        /// identifier is a name nobody else uses; a human name is not, so a name
        /// match is selected only where `SafetyEngine` finds it clearly the
        /// application's.
        static func tier(for rule: Rule, in domain: FileSystemRoot.Domain) -> EvidenceTier {
            if FileSystemRoot.onlyNameMatchable(domain) {
                return .C
            }
            switch rule {
            case .bundleIdentifier, .bundleIdentifierFile, .bundleIdentifierPrefix,
                 .identifierInsideBundle:
                return .B
            case .bundleIdentifierDelimitedPrefix:
                return .C
            case .temporaryDirectory, .clientOfService:
                return .B
            case .groupContainer:
                return .A
            case .applicationName, .applicationNameLowercased,
                 .applicationNameDelimitedPrefix, .homeDotFolder, .diagnosticReport:
                return .C
            }
        }

        /// Names the forward search can test without reading a bundle.
        public func candidates(for identity: Identity) -> [String] {
            candidates(for: Subject(identity))
        }

        public func candidates(for subject: Subject) -> [String] {
            switch rule {
            case .bundleIdentifier:
                return subject.identifiers
            case let .bundleIdentifierFile(ext):
                return subject.identifiers.map { "\($0).\(ext)" }
            case .bundleIdentifierPrefix:
                return subject.identifiers.flatMap { ["\($0).plist", $0] }
            case .bundleIdentifierDelimitedPrefix, .temporaryDirectory, .clientOfService,
                 .applicationNameDelimitedPrefix, .identifierInsideBundle, .diagnosticReport:
                return []
            case .groupContainer:
                if !subject.groups.isEmpty {
                    return subject.groups
                }
                return subject.identifiers.map { "group.\($0)" }
            case .applicationName:
                return subject.names
            case .applicationNameLowercased:
                return subject.lowercasedNames
            case .homeDotFolder:
                return subject.homeFolders + subject.lowercasedNames.map { "." + $0 }
            }
        }

        /// The same ownership rule is used when searching from an app and
        /// when checking whether a swept path still belongs to one.
        public func matchTier(name: String, identity: Identity, declaredIdentifier: String? = nil) -> EvidenceTier? {
            matchTier(name: name, subject: Subject(identity), declaredIdentifier: declaredIdentifier)
        }

        public func matchTier(name: String, subject: Subject, declaredIdentifier: String? = nil) -> EvidenceTier? {
            switch rule {
            // In any case and spacing: `Caches/Codex` belongs to an app whose
            // identifier says `codex`.
            case .applicationName, .applicationNameLowercased:
                subject.nameKeys.contains(NameKey.of(name)) ? tier : nil
            case let .applicationNameDelimitedPrefix(separator):
                delimitedPrefixTier(name: name, keys: subject.prefixKeys, separator: separator)
            case .groupContainer:
                groupTier(name: name, subject: subject)
            case .homeDotFolder:
                homeFolderTier(name: name, subject: subject)
            case .diagnosticReport:
                subject.names.contains { Self.isReport(name, of: $0) } ? tier : nil
            default:
                identifierTier(name: name, subject: subject, declaredIdentifier: declaredIdentifier)
            }
        }

        private func identifierTier(
            name: String, subject: Subject, declaredIdentifier: String?
        ) -> EvidenceTier? {
            switch rule {
            case .bundleIdentifier:
                guard subject.identifierSet.contains(name) else { return nil }
                return subject.owns(name) ? tier : .C
            case let .bundleIdentifierFile(ext):
                return identifierFileTier(name: name, extension: ext, subject: subject)
            case .bundleIdentifierPrefix:
                guard let matched = subject.longestIdentifier(prefixing: name) else { return nil }
                return subject.owns(matched) ? tier : .C
            case let .bundleIdentifierDelimitedPrefix(separator):
                return subject.identifiers.contains(where: {
                    name.hasPrefix($0 + separator) && name.count > $0.count + separator.count
                }) ? .C : nil
            case .temporaryDirectory:
                return temporaryDirectoryTier(name: name, subject: subject)
            case .clientOfService:
                return clientTier(name: name, subject: subject)
            case .identifierInsideBundle:
                // A plug-in is often named inside a component's identifier,
                // `com.openai.sky.CUAService.AuthorizationPlugin` for one.
                return declaredIdentifierTier(declaredIdentifier, subject: subject)
            case .applicationName, .applicationNameLowercased,
                 .applicationNameDelimitedPrefix, .groupContainer, .homeDotFolder, .diagnosticReport:
                return nil
            }
        }

        private func temporaryDirectoryTier(name: String, subject: Subject) -> EvidenceTier? {
            guard let matched = subject.identifiers.first(where: {
                Self.isTemporary(name: name, of: $0)
            }) else { return nil }
            return subject.owns(matched) ? tier : .C
        }

        private func identifierFileTier(name: String, extension ext: String, subject: Subject) -> EvidenceTier? {
            guard name.hasSuffix("." + ext) else { return nil }
            let stem = String(name.dropLast(ext.count + 1))
            guard subject.identifierSet.contains(stem) else { return nil }
            return subject.owns(stem) ? tier : .C
        }

        private func clientTier(name: String, subject: Subject) -> EvidenceTier? {
            guard let plus = name.lastIndex(of: "+"), plus != name.startIndex else { return nil }
            let client = String(name[name.index(after: plus)...])
            guard subject.identifierSet.contains(client) else { return nil }
            return subject.owns(client) ? tier : .C
        }

        private func declaredIdentifierTier(_ identifier: String?, subject: Subject) -> EvidenceTier? {
            guard let identifier,
                  subject.longestIdentifier(prefixing: identifier) != nil else { return nil }
            return subject.owns(identifier) ? tier : .C
        }

        /// The bundle's own declaration is a record and outranks the home
        /// folder's name-only floor; a folder sharing the name is a guess.
        private func homeFolderTier(name: String, subject: Subject) -> EvidenceTier? {
            if subject.homeFolderSet.contains(name) {
                return .B
            }
            guard name.hasPrefix(".") else { return nil }
            let bare = String(name.dropFirst()).lowercased()
            if subject.nameKeys.contains(NameKey.of(bare)) {
                return .C
            }
            return subject.lowercasedNames.contains(where: { lower in
                bare.hasPrefix(lower + "-") && bare.count > lower.count + 1
            }) ? .C : nil
        }

        /// `<process>-<date>` or `<process>_<date>`, the date's first digit
        /// right after the separator.
        static func isReport(_ file: String, of process: String) -> Bool {
            for separator in ["-", "_"] where file.hasPrefix(process + separator) {
                let rest = file.dropFirst(process.count + 1)
                if rest.prefix(4).allSatisfy(\.isNumber), rest.count > 4 {
                    return true
                }
            }
            return false
        }

        /// Inside the identifier's namespace, hidden or not. Another
        /// installed application whose identifier is longer is vetoed in
        /// `TierSVetoEngine.namedFor`.
        static func isTemporary(name: String, of identifier: String) -> Bool {
            let visible = name.hasPrefix(".") ? String(name.dropFirst()) : name
            return visible.hasPrefix(identifier + ".") && visible.count > identifier.count + 1
        }

        private func delimitedPrefixTier(
            name: String, keys: Set<String>, separator: String
        ) -> EvidenceTier? {
            // The part before any separator, compared as names are, so
            // `ChatGPTHelper.binarycookies` answers to `ChatGPT Helper`.
            var rest = name[...]
            while let range = rest.range(of: separator) {
                let stem = name[..<range.lowerBound]
                if !stem.isEmpty, range.upperBound < name.endIndex, keys.contains(NameKey.of(String(stem))) {
                    return .C
                }
                rest = name[range.upperBound...]
            }
            return nil
        }

        private func groupTier(name: String, subject: Subject) -> EvidenceTier? {
            if subject.groupSet.contains(name) {
                return .A
            }
            guard subject.groups.isEmpty, name.hasPrefix("group."),
                  subject.identifierSet.contains(String(name.dropFirst(6)))
            else { return nil }
            return .C
        }
    }

    /// What one identity answers to, worked out once. `Identity` derives its
    /// identifiers each time it is asked, and an app like Xcode has 135 of them.
    public struct Subject: Sendable {
        public let identifiers: [String]
        let identifierSet: Set<String>
        let names: [String]
        let lowercasedNames: [String]
        let nameKeys: Set<String>
        /// The names, and `<name> Helper` for each, as the start of a name,
        /// compared as names are.
        let prefixKeys: Set<String>
        let groups: [String]
        let groupSet: Set<String>
        let homeFolders: [String]
        let homeFolderSet: Set<String>
        private let own: String?

        public init(_ identity: Identity) {
            identifiers = identity.searchBundleIdentifiers
            identifierSet = Set(identifiers)
            names = identity.searchNames
            var seen = Set<String>()
            lowercasedNames = names.map { $0.lowercased() }.filter { seen.insert($0).inserted }
            nameKeys = Set(names.map(NameKey.of).filter { !$0.isEmpty })
            prefixKeys = Set((names + identity.helperNames).map(NameKey.of).filter { !$0.isEmpty })
            groups = identity.searchGroupContainers
            groupSet = Set(groups)
            homeFolders = identity.searchHomeFolders
            homeFolderSet = Set(homeFolders)
            own = identity.bundleID.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        }

        /// The same answer as `Identity.ownsIdentifier`.
        func owns(_ identifier: String) -> Bool {
            guard let own else { return false }
            let other = identifier.lowercased()
            return other == own || other.hasPrefix(own + ".")
        }

        /// The longest identifier that is the name or a dotted prefix of
        /// it, found by walking the name's own prefixes.
        public func longestIdentifier(prefixing name: String) -> String? {
            if identifierSet.contains(name) {
                return name
            }
            var end = name.endIndex
            while let dot = name[..<end].lastIndex(of: ".") {
                let prefix = String(name[..<dot])
                if identifierSet.contains(prefix) {
                    return prefix
                }
                end = dot
            }
            return nil
        }
    }

    /// The domains a sweep for leftovers walks, derived from the same table the
    /// uninstall uses so the two cannot drift apart. Leaves out what a sweep
    /// cannot reason about: application folders, other volumes and accounts,
    /// and the system's temporary directory.
    public static var sweepDomains: [FileSystemRoot.Domain] {
        var seen: Set<FileSystemRoot.Domain> = []
        var result: [FileSystemRoot.Domain] = []
        for location in standard.locations where !notWorthSweeping.contains(location.domain) {
            if seen.insert(location.domain).inserted {
                result.append(location.domain)
            }
        }
        return result
    }

    static let notWorthSweeping: Set<FileSystemRoot.Domain> = [
        // Nothing there can be removed by Brim, so a sweep would only offer
        // rows that refuse.
        .systemSecurityAgentPlugins,
        .applications, .userApplications, .volumes, .users, .tempDirs,
        // Fonts have no owning application, and a sweep of them is a list
        // of every typeface somebody has ever installed.
        .userFonts, .systemFonts,
        // Per-boot scratch space every process writes to and macOS empties. It
        // stays in the inventory for uninstalls, but sweeping it lists only
        // transient files.
        .darwinUserTemp
    ]

    public let locations: [Location]

    public init(locations: [Location]) {
        self.locations = locations
    }

    /// The inventory Brim uses.
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
        // Prefixed rather than exact: an app that updates itself leaves
        // `<identifier>.ShipIt`, and a helper often keeps its folder under the
        // app's identifier. The prefix is the identifier and a dot, so
        // `com.example.app` does not reach `com.example.applet`. Still Tier B.
        Location(domain: .userApplicationSupport, rule: .bundleIdentifierPrefix,
                 describes: "supporting files",
                 sentence: "Application Support keyed to the bundle identifier."),
        Location(domain: .userContainers, rule: .bundleIdentifier,
                 describes: "sandbox data",
                 sentence: "Container keyed to the bundle identifier."),
        Location(domain: .systemContainers, rule: .bundleIdentifier,
                 describes: "sandbox data for every user",
                 sentence: "Container for every user, keyed to the bundle identifier."),
        Location(domain: .userGroupContainers, rule: .groupContainer,
                 describes: "shared app data",
                 sentence: "Group container declared by this app, or matched by name only."),
        Location(domain: .userWebKit, rule: .bundleIdentifier,
                 describes: "web data",
                 sentence: "WebKit data keyed to the bundle identifier."),
        Location(domain: .systemApplicationSupport, rule: .bundleIdentifierPrefix,
                 describes: "supporting files for every user",
                 sentence: "Application Support for every user, keyed to the bundle identifier."),
        Location(domain: .userCaches, rule: .bundleIdentifierPrefix,
                 describes: "caches",
                 sentence: "A cache folder keyed to the bundle identifier."),
        Location(domain: .systemCaches, rule: .bundleIdentifierPrefix,
                 describes: "caches for every user",
                 sentence: "A cache folder for every user, keyed to the bundle identifier."),
        // A folder named for the application in Caches or Logs. A name match, so
        // Tier C, ticked only when clearly the application's.
        Location(domain: .userCaches, rule: .applicationName,
                 describes: "caches",
                 sentence: "A cache folder named after the application rather than its "
                     + "identifier."),
        // The name and a hyphen, how an editor's extensions name theirs:
        // `Caches/vscode-cpptools`.
        Location(domain: .userCaches, rule: .applicationNameDelimitedPrefix("-"),
                 describes: "caches",
                 sentence: "A cache folder beginning with the application's name."),
        Location(domain: .userLogs, rule: .applicationNameDelimitedPrefix("-"),
                 describes: "logs",
                 sentence: "A log folder beginning with the application's name."),
        Location(domain: .userLogs, rule: .applicationName,
                 describes: "logs",
                 sentence: "A log folder named after the application rather than its "
                     + "identifier."),
        Location(domain: .userApplicationSupport, rule: .applicationName,
                 describes: "supporting files",
                 sentence: "Application Support named after the application rather than its "
                     + "identifier."),
        Location(domain: .userApplicationSupport, rule: .applicationNameDelimitedPrefix("-"),
                 describes: "supporting files",
                 sentence: "A support folder beginning with the application's name."),
        Location(domain: .userSavedApplicationState, rule: .bundleIdentifierPrefix,
                 describes: "saved windows",
                 sentence: "The windows and documents macOS reopens for this application."),
        // The recent-documents record, keyed on the bundle identifier. The record
        // goes with the application; the documents it names never do
        // (`RecordedPathTests`).
        Location(domain: .userRecentDocuments, rule: .bundleIdentifierFile("sfl4"),
                 describes: "recently opened documents",
                 sentence: "The list macOS keeps of documents this application opened. The "
                     + "list goes; the documents stay where they are."),
        Location(domain: .userHTTPStorages, rule: .bundleIdentifierPrefix,
                 describes: "stored web data",
                 sentence: "Cookies and web storage macOS keeps for this application."),
        // A process with no bundle of its own gets web storage under its
        // executable's name, such as `ChatGPTHelper.binarycookies`.
        Location(domain: .userHTTPStorages, rule: .applicationName,
                 describes: "stored web data",
                 sentence: "Web storage named after one of this application's processes."),
        Location(domain: .userHTTPStorages, rule: .applicationNameDelimitedPrefix("."),
                 describes: "cookies",
                 sentence: "Cookies named after one of this application's processes."),
        Location(domain: .userCloudKitCaches, rule: .bundleIdentifier,
                 describes: "iCloud cache",
                 sentence: "The cache iCloud keeps for this application, keyed to its identifier."),
        Location(domain: .userCookies, rule: .bundleIdentifierPrefix,
                 describes: "cookies",
                 sentence: "Cookies keyed to the bundle identifier."),
        Location(domain: .userApplicationScripts, rule: .bundleIdentifier,
                 describes: "automation scripts",
                 sentence: "The folder macOS gives a sandboxed application for its scripts."),
        Location(domain: .userApplicationScripts, rule: .groupContainer,
                 describes: "shared automation scripts",
                 sentence: "Automation scripts for a declared app group, or matched by name only."),
        Location(domain: .systemApplicationScripts, rule: .bundleIdentifier,
                 describes: "automation scripts for every user",
                 sentence: "Application scripts keyed to the bundle identifier."),
        Location(domain: .systemApplicationScripts, rule: .groupContainer,
                 describes: "shared automation scripts for every user",
                 sentence: "Application scripts for a declared group, or matched by name only."),
        Location(domain: .userAutosaveInformation, rule: .bundleIdentifierPrefix,
                 describes: "autosaved documents",
                 sentence: "Documents this application autosaved but never closed."),
        Location(domain: .userLogs, rule: .bundleIdentifier,
                 describes: "logs",
                 sentence: "A log folder keyed to the bundle identifier."),
        Location(domain: .systemLogs, rule: .bundleIdentifier,
                 describes: "logs for every user",
                 sentence: "A log folder for every user, keyed to the bundle identifier."),
        Location(domain: .userDiagnosticReports, rule: .diagnosticReport,
                 describes: "crash reports",
                 sentence: "Crash reports named after this application. These accumulate for "
                     + "years and nothing removes them."),
        Location(domain: .systemDiagnosticReports, rule: .diagnosticReport,
                 describes: "crash reports",
                 sentence: "Crash reports named after this application."),

        // The plug-in folders, where the identifier is inside the bundle.
        Location(domain: .userInternetPlugIns, rule: .identifierInsideBundle,
                 describes: "an Internet plug-in",
                 sentence: "An Internet plug-in whose own Info.plist declares this identifier."),
        Location(domain: .userDictionaries, rule: .identifierInsideBundle,
                 describes: "a dictionary",
                 sentence: "A dictionary whose own Info.plist declares this identifier."),
        Location(domain: .systemDictionaries, rule: .identifierInsideBundle,
                 describes: "a dictionary for every user",
                 sentence: "A dictionary whose own Info.plist declares this identifier."),
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
        Location(domain: .userServices, rule: .applicationNameDelimitedPrefix(" - "),
                 describes: "a Services menu item",
                 sentence: "A Services workflow beginning with the application's name."),
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
        // How the Mac signs in and unlocks. Found so the review can say it
        // stays and why; never removed (`HelperScope.signInFolders`).
        Location(domain: .systemSecurityAgentPlugins, rule: .identifierInsideBundle,
                 describes: "a sign-in plug-in",
                 sentence: "A plug-in in how this Mac signs in or unlocks, whose own Info.plist "
                     + "declares this identifier."),
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
        Location(domain: .darwinUserCache, rule: .bundleIdentifierDelimitedPrefix("-"),
                 describes: "a per-boot cache",
                 sentence: "A cache beginning with the application's identifier."),
        // Outside `~/Library`, where cross-platform software keeps its data.
        // Lower case on purpose, matching the convention there.
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
        Location(domain: .userHomeDotFolders, rule: .homeDotFolder,
                 describes: "data in your home folder",
                 sentence: "A hidden folder in your home folder. Either the application names "
                     + "it as its own, or it carries the application's name."),
        Location(domain: .darwinUserTemp, rule: .bundleIdentifier,
                 describes: "per-boot temporary files",
                 sentence: "Temporary files in the per-user folder macOS makes fresh each boot."),
        Location(domain: .darwinUserTemp, rule: .temporaryDirectory,
                 describes: "scratch folders",
                 sentence: "Named inside the application's identifier, in the per-user folder."),
        Location(domain: .darwinUserCache, rule: .clientOfService,
                 describes: "web view caches",
                 sentence: "Kept by a macOS service on the application's behalf, and named for it."),
        // WebKit makes the same three folders in the temporary sibling as in the
        // cache folder.
        Location(domain: .darwinUserTemp, rule: .clientOfService,
                 describes: "web view scratch folders",
                 sentence: "Kept by a macOS service on the application's behalf, and named for it."),
        Location(domain: .darwinUserCache, rule: .temporaryDirectory,
                 describes: "scratch folders",
                 sentence: "Named inside the application's identifier, in the per-user folder.")
    ])
}
