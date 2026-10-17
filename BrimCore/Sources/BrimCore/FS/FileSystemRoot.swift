import Foundation

/// The root every domain is resolved against, so `BrimCore` never uses a
/// hard-coded absolute path.
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
        /// The recent-documents list macOS keeps per application,
        /// `<identifier>.sfl4`. The record goes with the application; the files it
        /// names are never touched (`RecordedPathTests`).
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
        /// `~/Applications`: apps installed for this user alone.
        case userApplications
        case receipts
        case tempDirs
        case volumes
        case users

        /// Per-machine preferences: a second copy of an application's settings,
        /// keyed by hardware, that a scan of `Preferences` walks past.
        case userPreferencesByHost
        case userHTTPStorages
        /// `Caches/CloudKit/<identifier>`, iCloud's cache for each application that
        /// syncs. One level below `Caches`, so the `Caches` rule never reaches it.
        case userCloudKitCaches
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

        // The plug-in folders. A plug-in's identifier is inside the bundle, not in
        // its name, so only reading the bundle attributes it.
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

        /// Where `pkgutil` keeps receipts now. `/Library/Receipts` is the old
        /// location.
        case systemReceipts
        case sharedUser
        case sharedApplicationSupport
        /// `confstr(_CS_DARWIN_USER_CACHE_DIR)`: a per-user directory nothing else
        /// enumerates.
        case darwinUserCache
        case darwinUserTemp

        // `~/.config`, where cross-platform software often keeps its real data
        // rather than in `~/Library`.
        case userDotConfig
        case userDotCache
        case userDotLocalShare
        case userDotLocalState
        case userDotLocalBin
        /// The home folder, for the dot folders software keeps there
        /// (`~/.vscode`). Only names beginning with a dot are considered; the rest
        /// is the person's own.
        case userHomeDotFolders
    }

    /// Whether a domain can only be matched on a name, which makes everything
    /// found there Tier C. A command line tool has no bundle or identifier, so
    /// only a shared name connects it to an application.
    public static func onlyNameMatchable(_ domain: Domain) -> Bool {
        switch domain {
        case .usrLocalBin, .usrLocalEtc, .usrLocalOpt,
             .usrLocalSbin, .usrLocalShare, .usrLocalVar,
             // Not the Darwin per-user folders: names there are bundle identifiers, the
             // same proof as `~/Library/Caches`.
             .sharedUser, .sharedApplicationSupport,
             // Nothing under `$HOME` carries a bundle identifier, so a match there is a
             // shared name and Tier C.
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
        case .userCloudKitCaches: home("Library/Caches/CloudKit")
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

    /// The per-user cache and temp directories under `/var/folders`. Found with
    /// `confstr`; under a fixture root, a stand-in inside the tree so tests
    /// never read the real machine's.
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
