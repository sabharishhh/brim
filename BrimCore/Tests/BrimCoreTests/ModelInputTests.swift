import BrimCore
import Testing

/// What the on-device model is given, decided by Brim before it is asked.
struct ModelInputTests {
    // MARK: - Release notes

    /// boringNotch's notes for 2.7.2 were one fix followed by the whole of
    /// 2.7.1 and 2.7. A summary of the full text described 2.7's Shelf
    /// update, which 2.7.2 did not contain.
    @Test func `notes are cut to the version they are about`() {
        let notes = """
        🚀 v2.7.2— Flying Rabbit Fixes: Fixed default sneak peak
        🚀 v2.7.1 — Flying Rabbit Fixes: Fixed update signing
        🚀 v2.7 — Shelf 2.0 Major update with a refreshed UI.
        """
        #expect(ReleaseNotesText.section(of: notes, version: "2.7.2")
            == "🚀 v2.7.2— Flying Rabbit Fixes: Fixed default sneak peak")
    }

    /// 2.8-rc.1's notes had no heading of their own and ended with
    /// "Compare v2.8-rc.0 → v2.8-rc.1". Matching on 2.8 alone took that
    /// link for the heading and kept only the changelog after it.
    @Test func `a pre-release is its own version, and a changelog link is not a heading`() {
        let notes = "What's New: Adds a compact player. Fixes artwork. "
            + "Full Changelog Compare v2.7.3 → v2.8-rc.0. Full Changelog Compare v2.8-rc.0 → v2.8-rc.1"
        #expect(ReleaseNotesText.section(of: notes, version: "2.8-rc.1") == ReleaseNotesText.tidy(notes))
    }

    @Test func `a version that is not a heading does not cut the notes`() {
        let notes = "Adds a compact player. Requires macOS 14.0 or later. Version 3.1 fixes a crash."
        #expect(ReleaseNotesText.section(of: notes, version: "3.2")
            == "Adds a compact player. Requires macOS 14.0 or later.")
        #expect(ReleaseNotesText.section(of: "Requires macOS 14.0. Fixes a crash.", version: "2.0")
            == "Requires macOS 14.0. Fixes a crash.")
    }

    @Test func `short notes are shown as written and a CVE is a security fix`() {
        #expect(ReleaseNotesText.isShort("Bug fixes and performance improvements."))
        #expect(!ReleaseNotesText.isShort(String(repeating: "word ", count: 13)))
        #expect(ReleaseNotesText.mentionsCVE("This release addresses CVE-2026-12345."))
        #expect(!ReleaseNotesText.mentionsCVE("Improves the security settings screen."))
    }

    // MARK: - Install scripts

    /// The model, asked to find what a script does, missed `killall` and
    /// cited the line before `rm -rf`. Brim's rules choose the lines now,
    /// so every line number is one the script has.
    @Test func `every line that does something is found, with its number`() {
        let script = """
        #!/bin/bash
        # We used to call kextload here.
        HELPER="com.vendorco.daemon"
        cp "$APP/Contents/Library/LaunchServices/$HELPER" /Library/PrivilegedHelperTools/
        cat > "/Library/LaunchDaemons/$HELPER.plist" <<PLIST
        <plist><dict><key>Program</key><string>/bin/launchctl</string></dict></plist>
        PLIST
        launchctl bootstrap system "/Library/LaunchDaemons/$HELPER.plist"
        security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.cer
        osascript -e 'tell application "System Events" to make login item at end'
        killall coreaudiod
        rm -rf "$HOME/Library/Caches/com.vendorco.meeting"
        """
        let found = InstallScriptReading.findings(in: script)
        #expect(found.map(\.line) == [4, 5, 8, 9, 10, 11, 12])
        #expect(found.map(\.phrase) == [
            "Installs a background service", "Installs a background service", "Starts or stops background jobs",
            "Trusts a certificate", "Changes login items", "Quits running programs", "Deletes files"
        ])
        #expect(found.last?.code == #"rm -rf "$HOME/Library/Caches/com.vendorco.meeting""#)
    }
}
