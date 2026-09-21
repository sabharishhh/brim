import XCTest
import BrimCore
@testable import BrimScan

/// Parsing PluginKit, which has no API and only a command.
final class AppExtensionSurfaceTests: XCTestCase {

    /// Copied from `pluginkit -m -v` on a real Mac, including the trailing
    /// count line and a path with a space in it.
    private static let realOutput = """
         com.apple.Music.MusicCacheExtension(1.7)\t98E337C2-E0C5-57B1-B0D2-8BD81F40DC50\t2026-09-17 05:49:43 +0000\t/System/Applications/Music.app/Contents/PlugIns/MusicCacheExtension.appex
    +    net.raymondhill.uBlock-Origin-Lite.Extension(2026.914.1325)\t267F0D05-79DE-45FB-A273-7FFF95C1CD13\t2026-09-17 05:49:40 +0000\t/Applications/uBlock Origin Lite.app/Contents/PlugIns/uBlock Origin Lite Extension.appex
         com.apple.fskit.msdos((null))\t05D73A57-A348-582A-87A6-C61B55B31409\t2026-09-14 19:43:20 +0000\t/System/Library/ExtensionKit/Extensions/com.apple.fskit.msdos.appex
     (490 plug-ins)
    """

    func testARealLineParses() {
        let entry = AppExtensionSurface.parse(
            "     com.apple.Music.MusicCacheExtension(1.7)\tUUID\tdate\t/System/x.appex"
        )
        XCTAssertEqual(entry?.identifier, "com.apple.Music.MusicCacheExtension")
        XCTAssertEqual(entry?.version, "1.7")
        XCTAssertEqual(entry?.path, "/System/x.appex")
        XCTAssertEqual(entry?.isEnabled, false)
    }

    func testAnEnabledExtensionIsMarked() {
        let entry = AppExtensionSurface.parse("+    com.example.Ext(1.0)\tU\td\t/Applications/A.appex")
        XCTAssertEqual(entry?.isEnabled, true)
    }

    func testAMissingVersionIsNotTheStringNull() {
        let entry = AppExtensionSurface.parse("     com.apple.fskit.msdos((null))\tU\td\t/System/x.appex")
        XCTAssertEqual(entry?.identifier, "com.apple.fskit.msdos")
        XCTAssertNil(entry?.version, "\"(null)\" is pluginkit saying there is no version")
    }

    func testAPathWithSpacesSurvives() {
        // The path is everything after the third tab, not the last
        // whitespace-separated field, because real ones contain spaces
        // and non-ASCII.
        let entry = AppExtensionSurface.parse(
            "     net.example.Ext(1.0)\tU\td\t/Applications/uBlock Origin Lite.app/Contents/PlugIns/uBlock Origin Lite Extension.appex"
        )
        XCTAssertEqual(
            entry?.path,
            "/Applications/uBlock Origin Lite.app/Contents/PlugIns/uBlock Origin Lite Extension.appex"
        )
    }

    func testTheClosingCountIsNotAnExtension() {
        XCTAssertNil(AppExtensionSurface.parse(" (490 plug-ins)"))
        XCTAssertNil(AppExtensionSurface.parse(""))
    }

    func testTheWholeListingParses() async {
        let surface = AppExtensionSurface(read: { Self.realOutput })
        let found = await surface.registrations(in: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")))

        XCTAssertEqual(found.count, 3, "The count line must not become a row")
        XCTAssertEqual(found.filter(\.isSystemOwned).count, 2, "Apple's are macOS's business")
        XCTAssertEqual(
            found.first { !$0.isSystemOwned }?.identifier,
            "net.raymondhill.uBlock-Origin-Lite.Extension"
        )
    }

    func testAToolThatDoesNotAnswerIsAGapRatherThanAnEmptyList() async {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let surface = AppExtensionSurface(read: { nil })

        let coverage = await surface.coverage(in: root)
        XCTAssertFalse(coverage.available, "Could not look is not nothing found")
        let found = await surface.registrations(in: root)
        XCTAssertTrue(found.isEmpty)
    }

    func testAnExtensionIsGroupedUnderItsApplication() {
        XCTAssertEqual(
            AppExtensionSurface.owningBundle(of: "net.whatsapp.WhatsApp.Intents"),
            "net.whatsapp.WhatsApp"
        )
        // Too short to split meaningfully; guessing would invent an owner.
        XCTAssertNil(AppExtensionSurface.owningBundle(of: "com.example.App"))
    }
}

/// System extensions: named, never acted on.
final class SystemExtensionSurfaceTests: XCTestCase {

    func testAnEmptyMachineIsACompleteAnswer() async {
        // `systemextensionsctl list` prints exactly this on a Mac with
        // none, which is a real answer and not a failure to look.
        let surface = SystemExtensionSurface(read: { "0 extension(s)\n" })
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

        let found = await surface.registrations(in: root)
        XCTAssertTrue(found.isEmpty)
        let coverage = await surface.coverage(in: root)
        XCTAssertTrue(coverage.available)
    }

    func testAnExtensionIsReportedAndRefused() {
        let output = """
        1 extension(s)
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tABCDE12345\tcom.example.vpn.extension (1.0/1.0)\tVPN\t[activated enabled]
        """
        let found = SystemExtensionSurface.parse(output)

        guard found.count == 1 else {
            return XCTFail("Expected one extension, parsed \(found.count)")
        }
        XCTAssertEqual(found[0].identifier, "com.example.vpn.extension")
        XCTAssertEqual(
            found[0].capability, .refusedByOS,
            "Only the host application can withdraw one, so Brim must not offer to"
        )
        XCTAssertTrue(found[0].evidence.contains("Brim"))
    }

    func testNothingHereIsJudgedStale() {
        // Guessing staleness from a status string would produce a row
        // offering an action that cannot work.
        let output = """
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tABCDE12345\tcom.example.gone.extension (1.0/1.0)\tGone\t[terminated waiting to uninstall on reboot]
        """
        let found = SystemExtensionSurface.parse(output)
        guard found.count == 1 else {
            return XCTFail("Expected one extension, parsed \(found.count)")
        }
        XCTAssertFalse(found[0].isActionableStale)
    }

    func testTheCountAndHeadersAreNotExtensions() {
        XCTAssertTrue(SystemExtensionSurface.parse("0 extension(s)").isEmpty)
        XCTAssertTrue(SystemExtensionSurface.parse(
            "--- com.apple.system_extension.network_extension"
        ).isEmpty)
    }
}

/// Lines in a shell profile that point at nothing.
final class ShellProfileSurfaceTests: XCTestCase {

    func testABrokenSourceLineIsFound() {
        XCTAssertEqual(
            ShellProfileSurface.pathReferenced(in: "source /opt/gone/init.sh"),
            "/opt/gone/init.sh"
        )
        XCTAssertEqual(
            ShellProfileSurface.pathReferenced(in: ". /opt/gone/init.sh"),
            "/opt/gone/init.sh"
        )
    }

    func testQuotesComeOff() {
        XCTAssertEqual(
            ShellProfileSurface.pathReferenced(in: "source \"/opt/gone/init.sh\""),
            "/opt/gone/init.sh"
        )
    }

    func testAPathEntryIsFound() {
        XCTAssertEqual(
            ShellProfileSurface.pathReferenced(in: "export PATH=/opt/gone/bin:$PATH"),
            "/opt/gone/bin"
        )
    }

    func testAnythingNeedingAShellIsLeftAlone() {
        // Working out what these mean requires running them, and running
        // somebody's shell configuration to find out what it does is the
        // thing this surface exists to avoid.
        XCTAssertNil(ShellProfileSurface.pathReferenced(in: "source $HOME/.cargo/env"))
        XCTAssertNil(ShellProfileSurface.pathReferenced(in: "source `brew --prefix`/x"))
        XCTAssertNil(ShellProfileSurface.pathReferenced(in: "source /opt/*/init.sh"))
    }

    func testCommentsAndOrdinaryLinesAreNotShown() {
        XCTAssertFalse(ShellProfileSurface.isWorthShowing("# source /opt/gone/init.sh"))
        XCTAssertFalse(ShellProfileSurface.isWorthShowing(""))
        XCTAssertFalse(ShellProfileSurface.isWorthShowing("alias ll='ls -la'"))
        XCTAssertTrue(ShellProfileSurface.isWorthShowing("source /opt/x/init.sh"))
    }
}

/// Report-only surfaces are never offered as something to act on.
final class ReportOnlyTests: XCTestCase {

    private func registration(_ kind: Registration.Kind) -> Registration {
        Registration(
            kind: kind, identifier: "x", label: "x",
            targetExists: false, evidence: "because"
        )
    }

    func testKeychainAndShellLinesAreNeverSwept() {
        // Both are stale by the letter of it, and offering an action that
        // does not exist is worse than not mentioning one.
        for kind in [Registration.Kind.keychainItem, .shellProfileLine] {
            let entry = registration(kind)
            XCTAssertTrue(entry.isStale)
            XCTAssertTrue(entry.isReportOnly)
            XCTAssertFalse(entry.isActionableStale, "\(kind) was offered as something to clean")
        }
    }

    func testOtherKindsAreStillActionable() {
        let job = registration(.launchdJob)
        XCTAssertTrue(job.isActionableStale)
        XCTAssertFalse(job.isReportOnly)
    }

    func testBrimSaysOutrightThatItDoesNotReadTheKeychain() async {
        let coverage = await KeychainSurface().coverage(
            in: FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        )
        XCTAssertFalse(coverage.available, "Silence would read as an empty keychain")
        XCTAssertTrue(coverage.limitation?.contains("Keychain Access") ?? false,
                      "A gap has to say what the person can do instead")
    }
}

/// A boundary is not a fault.
///
/// The keychain, which Brim deliberately does not read, appeared in the
/// running app under "Part of this list is missing" with a button
/// offering to open Full Disk Access. Full Disk Access was already
/// granted, so the screen told somebody their Mac was misconfigured,
/// pointed them at a switch that was already on, and would have changed
/// nothing if it had not been.
final class CoverageAbsenceTests: XCTestCase {

    func testSomethingBrimWillNotReadIsNotReportedAsAFault() {
        let withheld = RegistrationCoverage.withheld(.keychainItem, "because")

        XCTAssertFalse(withheld.available)
        XCTAssertFalse(withheld.isAFault, "A choice is not a malfunction")
        XCTAssertFalse(
            withheld.isFixableByTheUser,
            "Offering Settings here sends somebody to flip a switch that changes nothing"
        )
        XCTAssertEqual(withheld.absence, .byDesign)
    }

    func testAPermissionGapOffersSomethingToPress() {
        let gap = RegistrationCoverage.unavailable(
            .launchdJob, "No launchd directory could be read.", absence: .needsPermission
        )
        XCTAssertTrue(gap.isAFault)
        XCTAssertTrue(gap.isFixableByTheUser)
    }

    func testAToolThatDidNotAnswerIsAFaultWithNothingToPress() {
        // Worth saying, because the list is short by an unknown amount.
        // Not worth a Settings button: no permission unblocks a tool that
        // failed to run.
        let gap = RegistrationCoverage.unavailable(
            .appExtension, "pluginkit did not answer."
        )
        XCTAssertTrue(gap.isAFault)
        XCTAssertFalse(gap.isFixableByTheUser)
    }

    func testAvailableSurfacesCarryNoAbsence() {
        let fine = RegistrationCoverage.available(.launchdJob)
        XCTAssertNil(fine.absence)
        XCTAssertFalse(fine.isAFault)
    }

    func testTheKeychainIsTheOneSurfaceHeldBack() async {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let coverage = await KeychainSurface().coverage(in: root)
        XCTAssertEqual(coverage.absence, .byDesign)
        XCTAssertFalse(coverage.isAFault)
    }
}
