import Foundation

/// Represents the root of the filesystem to ensure `BrimCore` never uses hardcoded absolute paths.
/// All domain lookups are resolved relative to this root.
public struct FileSystemRoot: Sendable {
    public let rootURL: URL
    public let userName: String

    public init(rootURL: URL = URL(fileURLWithPath: "/"), userName: String = NSUserName()) {
        self.rootURL = rootURL.resolvingSymlinksInPath()
        self.userName = userName
    }

    public enum Domain: Sendable, Equatable, Hashable {
        case userLibrary
        case userPreferences
        case userApplicationSupport
        /// The shared file list macOS keeps of the documents an application
        /// most recently opened, one `<identifier>.sfl4` per application.
        ///
        /// It is a record about the application and it names the person's
        /// own files. The record goes with the application; what it points
        /// at is never touched. `RecordedPathTests` holds that line.
        case userRecentDocuments
        case userCaches
        case userSavedApplicationState
        case userLogs
        case userWebKit
        case userContainers
        case userGroupContainers
        case userLaunchAgents
        case systemLibrary
        case systemLaunchDaemons
        case systemLaunchAgents
        case applications
        /// `~/Applications` — apps installed for this user alone.
        case userApplications
        case receipts
        case tempDirs
        case volumes
        case users

        // Everything below was missing, and each one is a real place
        // software hides. Nineteen locations found less than AppCleaner
        // does; the point of a footprint is that it is the whole
        // footprint.

        /// Per-machine preferences. A second copy of an application's
        /// settings, keyed by hardware, that a scan of `Preferences`
        /// walks straight past.
        case userPreferencesByHost
        case userHTTPStorages
        case userCookies
        case userApplicationScripts
        case systemApplicationScripts
        case userAutosaveInformation
        /// Crash logs, which name the application that crashed and
        /// accumulate for years after it is gone.
        case userDiagnosticReports
        case systemDiagnosticReports
        case systemLogs
        case systemApplicationSupport
        case systemPreferences
        case systemCaches
        case systemContainers

        // The plug-in folders. Audio plug-ins in particular are invisible
        // to any scan keyed on a bundle identifier in a path, because the
        // identifier is inside the bundle rather than in its name.
        case userInternetPlugIns
        case systemInternetPlugIns
        case userPreferencePanes
        case systemPreferencePanes
        case userServices
        case systemServices
        case userQuickLook
        case systemQuickLook
        case userSpotlight
        case systemSpotlight
        case userAutomator
        case systemAutomator
        case userColorPickers
        case systemColorPickers
        case userScreenSavers
        case systemScreenSavers
        case userFonts
        case systemFonts
        case userWidgets
        case userAudioComponents
        case systemAudioComponents
        case systemAudioVST
        case systemAudioVST3
        case systemAudioCLAP
        case systemAudioHAL
        case systemSecurityAgentPlugins
        case systemAudioMAS
        case systemAudioAvid
        case systemExtensionsFolder
        case userDictionaries
        case systemDictionaries
        case privilegedHelperTools
        case startupItems

        /// Command line tools, which have no bundle at all and so are
        /// invisible to every identifier-keyed scan.
        case usrLocalBin
        case usrLocalEtc
        case usrLocalOpt
        case usrLocalSbin
        case usrLocalShare
        case usrLocalVar

        /// Where `pkgutil` really keeps receipts. `/Library/Receipts` is
        /// the old location and is empty on a modern Mac.
        case systemReceipts
        case sharedUser
        case sharedApplicationSupport
        /// `confstr(_CS_DARWIN_USER_CACHE_DIR)` and its temp sibling: a
        /// per-user, per-boot directory that nothing else enumerates.
        case darwinUserCache
        case darwinUserTemp

        // The convention macOS never adopted and most cross-platform
        // software follows anyway. Software written for Linux first keeps
        // its real data here because that is where its other builds already
        // look, and porting to `~/Library` is work nobody does. Nothing in
        // Brim looked at `$HOME` directly, so the largest single thing any
        // of these applications had on this Mac, 189 MB under
        // `~/.local/share/claude`, was invisible to every evidence source.
        case userDotConfig
        case userDotCache
        case userDotLocalShare
        case userDotLocalState
        case userDotLocalBin
        /// The home folder itself, for the dot folders software keeps
        /// there: `~/.vscode`, `~/.antigravity-ide`. Only names beginning
        /// with a dot are ever considered, because the rest of the home
        /// folder is the person's own.
        case userHomeDotFolders
    }

    /// Whether a domain can only be matched on a name, which makes
    /// everything found there Tier C by construction.
    ///
    /// A command line tool has no bundle and no identifier. The only
    /// thing connecting `/usr/local/bin/foo` to an application is that
    /// somebody called them both "foo", and the specification is explicit
    /// that such a location is Tier C and has to be labelled as one.
    public static func onlyNameMatchable(_ domain: Domain) -> Bool {
        switch domain {
        case .usrLocalBin, .usrLocalEtc, .usrLocalOpt,
             .usrLocalSbin, .usrLocalShare, .usrLocalVar,
             // Not the Darwin per-user folders: what sits there is named
             // after a bundle identifier, the same proof as `~/Library/Caches`.
             // Counted as name-only, a folder called exactly
             // `com.openai.codex.helper` was a guess and outlived the app.
             .sharedUser, .sharedApplicationSupport,
             // Nothing under `$HOME` carries a bundle identifier. A folder
             // there is linked to an application by a shared name and
             // nothing else, which is the definition of Tier C.
             .userDotConfig, .userDotCache, .userDotLocalShare,
             .userDotLocalState, .userDotLocalBin, .userHomeDotFolders:
            true
        default:
            false
        }
    }

    /// Resolves the absolute URL for a given domain relative to this root.
    public func url(for domain: Domain) -> URL {
        switch domain {
        case .userLibrary:
            rootURL.appendingPathComponent("Users/\(userName)/Library")
        case .userPreferences:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Preferences")
        case .userApplicationSupport:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Application Support")
        case .userRecentDocuments:
            rootURL.appendingPathComponent(
                "Users/\(userName)/Library/Application Support/com.apple.sharedfilelist"
                    + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            )
        case .userCaches:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Caches")
        case .userSavedApplicationState:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Saved Application State")
        case .userLogs:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Logs")
        case .userWebKit:
            rootURL.appendingPathComponent("Users/\(userName)/Library/WebKit")
        case .userContainers:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Containers")
        case .userGroupContainers:
            rootURL.appendingPathComponent("Users/\(userName)/Library/Group Containers")
        case .userLaunchAgents:
            rootURL.appendingPathComponent("Users/\(userName)/Library/LaunchAgents")
        case .systemLibrary:
            rootURL.appendingPathComponent("Library")
        case .systemLaunchDaemons:
            rootURL.appendingPathComponent("Library/LaunchDaemons")
        case .systemLaunchAgents:
            rootURL.appendingPathComponent("Library/LaunchAgents")
        case .applications:
            rootURL.appendingPathComponent("Applications")
        case .userApplications:
            rootURL.appendingPathComponent("Users/\(userName)/Applications")
        case .receipts:
            rootURL.appendingPathComponent("Library/Receipts")
        case .tempDirs:
            rootURL.appendingPathComponent("private/tmp")
        case .volumes:
            rootURL.appendingPathComponent("Volumes")
        case .users:
            rootURL.appendingPathComponent("Users")
        case .userPreferencesByHost: home("Library/Preferences/ByHost")
        case .userHTTPStorages: home("Library/HTTPStorages")
        case .userCookies: home("Library/Cookies")
        case .userApplicationScripts: home("Library/Application Scripts")
        case .systemApplicationScripts: system("Library/Application Scripts")
        case .userAutosaveInformation: home("Library/Autosave Information")
        case .userDiagnosticReports: home("Library/Logs/DiagnosticReports")
        case .systemDiagnosticReports: system("Library/Logs/DiagnosticReports")
        case .systemLogs: system("Library/Logs")
        case .systemApplicationSupport: system("Library/Application Support")
        case .systemPreferences: system("Library/Preferences")
        case .systemCaches: system("Library/Caches")
        case .systemContainers: system("Library/Containers")
        case .userDictionaries: home("Library/Dictionaries")
        case .systemDictionaries: system("Library/Dictionaries")
        case .userInternetPlugIns: home("Library/Internet Plug-Ins")
        case .systemInternetPlugIns: system("Library/Internet Plug-Ins")
        case .userPreferencePanes: home("Library/PreferencePanes")
        case .systemPreferencePanes: system("Library/PreferencePanes")
        case .userServices: home("Library/Services")
        case .systemServices: system("Library/Services")
        case .userQuickLook: home("Library/QuickLook")
        case .systemQuickLook: system("Library/QuickLook")
        case .userSpotlight: home("Library/Spotlight")
        case .systemSpotlight: system("Library/Spotlight")
        case .userAutomator: home("Library/Automator")
        case .systemAutomator: system("Library/Automator")
        case .userColorPickers: home("Library/ColorPickers")
        case .systemColorPickers: system("Library/ColorPickers")
        case .userScreenSavers: home("Library/Screen Savers")
        case .systemScreenSavers: system("Library/Screen Savers")
        case .userFonts: home("Library/Fonts")
        case .systemFonts: system("Library/Fonts")
        case .userWidgets: home("Library/Widgets")
        case .userAudioComponents: home("Library/Audio/Plug-Ins/Components")
        case .systemAudioComponents: system("Library/Audio/Plug-Ins/Components")
        case .systemAudioVST: system("Library/Audio/Plug-Ins/VST")
        case .systemAudioVST3: system("Library/Audio/Plug-Ins/VST3")
        case .systemAudioCLAP: system("Library/Audio/Plug-Ins/CLAP")
        case .systemAudioHAL: system("Library/Audio/Plug-Ins/HAL")
        case .systemSecurityAgentPlugins: system("Library/Security/SecurityAgentPlugins")
        case .systemAudioMAS: system("Library/Audio/Plug-Ins/MAS")
        case .systemAudioAvid: system("Library/Application Support/Avid/Audio/Plug-Ins")
        case .systemExtensionsFolder: system("Library/Extensions")
        case .privilegedHelperTools: system("Library/PrivilegedHelperTools")
        case .startupItems: system("Library/StartupItems")
        case .usrLocalBin: rootURL.appendingPathComponent("usr/local/bin")
        case .usrLocalEtc: rootURL.appendingPathComponent("usr/local/etc")
        case .usrLocalOpt: rootURL.appendingPathComponent("usr/local/opt")
        case .usrLocalSbin: rootURL.appendingPathComponent("usr/local/sbin")
        case .usrLocalShare: rootURL.appendingPathComponent("usr/local/share")
        case .usrLocalVar: rootURL.appendingPathComponent("usr/local/var")
        case .systemReceipts: rootURL.appendingPathComponent("private/var/db/receipts")
        case .sharedUser: rootURL.appendingPathComponent("Users/Shared")
        case .sharedApplicationSupport:
            rootURL.appendingPathComponent("Users/Shared/Library/Application Support")
        case .darwinUserCache: Self.darwinDirectory(_CS_DARWIN_USER_CACHE_DIR, in: rootURL)
        case .darwinUserTemp: Self.darwinDirectory(_CS_DARWIN_USER_TEMP_DIR, in: rootURL)
        case .userDotConfig: home(".config")
        case .userDotCache: home(".cache")
        case .userDotLocalShare: home(".local/share")
        case .userDotLocalState: home(".local/state")
        case .userDotLocalBin: home(".local/bin")
        case .userHomeDotFolders: rootURL.appendingPathComponent("Users/\(userName)")
        }
    }

    private func home(_ relative: String) -> URL {
        rootURL.appendingPathComponent("Users/\(userName)/\(relative)")
    }

    private func system(_ relative: String) -> URL {
        rootURL.appendingPathComponent(relative)
    }

    /// The per-user, per-boot cache and temp directories.
    ///
    /// `/var/folders/xy/…`, which nothing enumerates and which holds a
    /// surprising amount: WebKit stores, application caches, saved state.
    /// There is no path to hard-code, only a `confstr` call, and under a
    /// fixture root it must not answer with the real machine's, so a root
    /// that is not `/` gets a stand-in inside the tree.
    static func darwinDirectory(_ name: Int32, in rootURL: URL) -> URL {
        guard rootURL.path == "/" else {
            let leaf = name == _CS_DARWIN_USER_CACHE_DIR ? "DarwinUserCache" : "DarwinUserTemp"
            return rootURL.appendingPathComponent("private/var/folders/\(leaf)")
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(name, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return URL(fileURLWithPath: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }
}
