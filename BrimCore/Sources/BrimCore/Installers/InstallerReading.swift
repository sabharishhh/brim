import Foundation

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
