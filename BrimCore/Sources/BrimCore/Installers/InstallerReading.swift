import Foundation

/// What an install script's text visibly does.
///
/// Read, never run, and never judged. A script can do anything its text
/// does not show, so this names the commands it calls in words a person
/// knows, and says nothing about whether calling them is good or bad.
/// Comment lines are skipped: a script that explains it no longer runs
/// `kextload` does not load a kernel extension.
public enum InstallScriptReading {
    /// Command names, the phrase for each, in the order a person would
    /// want to read them: what runs, what changes the system, then the rest.
    static let commands: [(names: [String], phrase: String)] = [
        (["launchctl"], "Starts or stops background jobs"),
        (["kextload", "kmutil"], "Loads a kernel extension"),
        (["systemextensionsctl"], "Changes system extensions"),
        (["sfltool"], "Changes login items"),
        (["tccutil"], "Resets privacy permissions"),
        (["spctl"], "Changes Gatekeeper settings"),
        (["xattr"], "Changes file attributes, such as quarantine"),
        (["curl", "wget"], "Downloads files"),
        (["osascript"], "Runs AppleScript"),
        (["killall", "pkill"], "Quits running programs"),
        (["dscl", "sysadminctl"], "Changes users or groups"),
        (["chown", "chmod"], "Changes file ownership or permissions")
    ]

    public static func calls(in text: String) -> [String] {
        var words = Set<String>()
        var changesSettings = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            // "defaults" is an ordinary word; the command is followed by
            // what it does.
            if trimmed.range(of: #"\bdefaults\s+(write|delete|import)\b"#, options: .regularExpression) != nil {
                changesSettings = true
            }
            // Words of letters, digits and dashes; a path's last part is a
            // word too, so `/bin/launchctl` counts as `launchctl`.
            for token in trimmed.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                words.insert(token.lowercased())
            }
        }
        var found = commands.filter { $0.names.contains(where: words.contains) }.map(\.phrase)
        if changesSettings {
            found.append("Changes settings")
        }
        return found
    }

    /// A script that is not text, such as a compiled program, cannot be
    /// read this way, and the preview says so.
    public static func isText(_ data: Data) -> Bool {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        return true
    }
}

/// The permissions an application says, in its `Info.plist`, it may ask
/// for. macOS shows each key's text in the prompt, so an app that does not
/// declare one cannot ask for that permission at all.
public enum DeclaredPermissions {
    static let keys: [(key: String, name: String)] = [
        ("NSCameraUsageDescription", "Camera"),
        ("NSMicrophoneUsageDescription", "Microphone"),
        ("NSScreenCaptureUsageDescription", "Screen recording"),
        ("NSLocationUsageDescription", "Location"),
        ("NSLocationWhenInUseUsageDescription", "Location"),
        ("NSLocationAlwaysAndWhenInUseUsageDescription", "Location"),
        ("NSContactsUsageDescription", "Contacts"),
        ("NSCalendarsUsageDescription", "Calendars"),
        ("NSCalendarsFullAccessUsageDescription", "Calendars"),
        ("NSRemindersUsageDescription", "Reminders"),
        ("NSRemindersFullAccessUsageDescription", "Reminders"),
        ("NSPhotoLibraryUsageDescription", "Photos"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth"),
        ("NSLocalNetworkUsageDescription", "Local network"),
        ("NSAppleEventsUsageDescription", "Control other apps"),
        ("NSDesktopFolderUsageDescription", "Desktop folder"),
        ("NSDocumentsFolderUsageDescription", "Documents folder"),
        ("NSDownloadsFolderUsageDescription", "Downloads folder"),
        ("NSRemovableVolumesUsageDescription", "Removable drives"),
        ("NSNetworkVolumesUsageDescription", "Network drives"),
        ("NSSpeechRecognitionUsageDescription", "Speech recognition"),
        ("NSHomeKitUsageDescription", "Home"),
        ("NSFocusStatusUsageDescription", "Focus status")
    ]

    public static func names(in info: [String: Any]) -> [String] {
        var names: [String] = []
        for entry in keys where info[entry.key] is String && !names.contains(entry.name) {
            names.append(entry.name)
        }
        return names
    }

    /// The bundle's frameworks that update it outside the App Store.
    public static func updater(inFrameworks names: [String]) -> String? {
        let known = ["Sparkle.framework": "Sparkle", "Squirrel.framework": "Squirrel"]
        return names.compactMap { known[$0] }.first
    }
}
