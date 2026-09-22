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
        case systemAudioMAS
        case systemAudioAvid
        case systemExtensionsFolder
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
             .darwinUserCache, .darwinUserTemp,
             .sharedUser, .sharedApplicationSupport:
            return true
        default:
            return false
        }
    }
    
    /// Resolves the absolute URL for a given domain relative to this root.
    public func url(for domain: Domain) -> URL {
        switch domain {
        case .userLibrary:
            return rootURL.appendingPathComponent("Users/\(userName)/Library")
        case .userPreferences:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Preferences")
        case .userApplicationSupport:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Application Support")
        case .userRecentDocuments:
            return rootURL.appendingPathComponent(
                "Users/\(userName)/Library/Application Support/com.apple.sharedfilelist"
                + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            )
        case .userCaches:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Caches")
        case .userSavedApplicationState:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Saved Application State")
        case .userLogs:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Logs")
        case .userWebKit:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/WebKit")
        case .userContainers:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Containers")
        case .userGroupContainers:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/Group Containers")
        case .userLaunchAgents:
            return rootURL.appendingPathComponent("Users/\(userName)/Library/LaunchAgents")
        case .systemLibrary:
            return rootURL.appendingPathComponent("Library")
        case .systemLaunchDaemons:
            return rootURL.appendingPathComponent("Library/LaunchDaemons")
        case .systemLaunchAgents:
            return rootURL.appendingPathComponent("Library/LaunchAgents")
        case .applications:
            return rootURL.appendingPathComponent("Applications")
        case .userApplications:
            return rootURL.appendingPathComponent("Users/\(userName)/Applications")
        case .receipts:
            return rootURL.appendingPathComponent("Library/Receipts")
        case .tempDirs:
            return rootURL.appendingPathComponent("private/tmp")
        case .volumes:
            return rootURL.appendingPathComponent("Volumes")
        case .users:
            return rootURL.appendingPathComponent("Users")

        case .userPreferencesByHost:  return home("Library/Preferences/ByHost")
        case .userHTTPStorages:       return home("Library/HTTPStorages")
        case .userCookies:            return home("Library/Cookies")
        case .userApplicationScripts: return home("Library/Application Scripts")
        case .userAutosaveInformation: return home("Library/Autosave Information")
        case .userDiagnosticReports:  return home("Library/Logs/DiagnosticReports")
        case .systemDiagnosticReports: return system("Library/Logs/DiagnosticReports")
        case .systemLogs:             return system("Library/Logs")
        case .systemApplicationSupport: return system("Library/Application Support")
        case .systemPreferences:      return system("Library/Preferences")
        case .systemCaches:           return system("Library/Caches")
        case .systemContainers:       return system("Library/Containers")

        case .userInternetPlugIns:    return home("Library/Internet Plug-Ins")
        case .systemInternetPlugIns:  return system("Library/Internet Plug-Ins")
        case .userPreferencePanes:    return home("Library/PreferencePanes")
        case .systemPreferencePanes:  return system("Library/PreferencePanes")
        case .userServices:           return home("Library/Services")
        case .systemServices:         return system("Library/Services")
        case .userQuickLook:          return home("Library/QuickLook")
        case .systemQuickLook:        return system("Library/QuickLook")
        case .userSpotlight:          return home("Library/Spotlight")
        case .systemSpotlight:        return system("Library/Spotlight")
        case .userAutomator:          return home("Library/Automator")
        case .systemAutomator:        return system("Library/Automator")
        case .userColorPickers:       return home("Library/ColorPickers")
        case .systemColorPickers:     return system("Library/ColorPickers")
        case .userScreenSavers:       return home("Library/Screen Savers")
        case .systemScreenSavers:     return system("Library/Screen Savers")
        case .userFonts:              return home("Library/Fonts")
        case .systemFonts:            return system("Library/Fonts")
        case .userWidgets:            return home("Library/Widgets")
        case .userAudioComponents:    return home("Library/Audio/Plug-Ins/Components")
        case .systemAudioComponents:  return system("Library/Audio/Plug-Ins/Components")
        case .systemAudioVST:         return system("Library/Audio/Plug-Ins/VST")
        case .systemAudioVST3:        return system("Library/Audio/Plug-Ins/VST3")
        case .systemAudioCLAP:        return system("Library/Audio/Plug-Ins/CLAP")
        case .systemAudioHAL:         return system("Library/Audio/Plug-Ins/HAL")
        case .systemAudioMAS:         return system("Library/Audio/Plug-Ins/MAS")
        case .systemAudioAvid:        return system("Library/Application Support/Avid/Audio/Plug-Ins")
        case .systemExtensionsFolder: return system("Library/Extensions")
        case .privilegedHelperTools:  return system("Library/PrivilegedHelperTools")
        case .startupItems:           return system("Library/StartupItems")

        case .usrLocalBin:            return rootURL.appendingPathComponent("usr/local/bin")
        case .usrLocalEtc:            return rootURL.appendingPathComponent("usr/local/etc")
        case .usrLocalOpt:            return rootURL.appendingPathComponent("usr/local/opt")
        case .usrLocalSbin:           return rootURL.appendingPathComponent("usr/local/sbin")
        case .usrLocalShare:          return rootURL.appendingPathComponent("usr/local/share")
        case .usrLocalVar:            return rootURL.appendingPathComponent("usr/local/var")

        case .systemReceipts:         return rootURL.appendingPathComponent("private/var/db/receipts")
        case .sharedUser:             return rootURL.appendingPathComponent("Users/Shared")
        case .sharedApplicationSupport:
            return rootURL.appendingPathComponent("Users/Shared/Library/Application Support")
        case .darwinUserCache:        return Self.darwinDirectory(_CS_DARWIN_USER_CACHE_DIR, in: rootURL)
        case .darwinUserTemp:         return Self.darwinDirectory(_CS_DARWIN_USER_TEMP_DIR, in: rootURL)
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
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
