import BrimCore
@testable import BrimScan
import Foundation
import Testing

/// Looking inside an installer before running it. Nothing here installs:
/// a package is expanded into a temporary folder with its payload still
/// compressed, and its file list read with `lsbom`.
struct InstallerPreviewTests {
    // MARK: - Package metadata

    @Test func `a package's own information names its bundles, scripts and install location`() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info identifier="com.example.demo.pkg" version="1.2" install-location="/" auth="root">
            <bundle path="./Applications/Demo.app" id="com.example.demo" CFBundleShortVersionString="1.2"/>
            <scripts>
                <preinstall file="./preinstall"/>
                <postinstall file="./postinstall" timeout="600"/>
            </scripts>
        </pkg-info>
        """
        let component = try #require(PackageComponent.parse(xml))
        #expect(component.identifier == "com.example.demo.pkg")
        #expect(component.installLocation == "/")
        #expect(component.runsAsRoot)
        #expect(component.bundles.first?.identifier == "com.example.demo")
        #expect(component.bundles.first?.version == "1.2")
        #expect(component.scripts.map(\.name) == ["preinstall", "postinstall"])
        #expect(PackageComponent.parse("<installer-gui-script/>") == nil)
    }

    @Test func `a localisation key is not a title`() throws {
        let named = try #require(PackageDistribution.parse("""
        <installer-gui-script><title>Demo Suite</title><domains enable_currentUserHome="true"/></installer-gui-script>
        """))
        #expect(named.title == "Demo Suite")
        #expect(named.mayInstallInHome)
        let keyed = try #require(
            PackageDistribution.parse("<installer-gui-script><title>SU_TITLE</title></installer-gui-script>")
        )
        #expect(keyed.title == nil)
        #expect(keyed.mayInstallInHome == false)
    }

    @Test func `the signer is the first certificate in the chain`() {
        let text = """
        Package "Demo.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Example Ltd (ABCDE12345)
               Expires: 2030-01-01 00:00:00 +0000
            2. Developer ID Certification Authority
        """
        let signed = PackageSignatureText.signer(in: text)
        #expect(signed?.signer == "Developer ID Installer: Example Ltd (ABCDE12345)")
        #expect(signed?.team == "ABCDE12345")
        #expect(PackageSignatureText.signer(in: "Package \"Demo.pkg\":\n   Status: no signature") == nil)
        let signature = InstallerSignature(signer: signed?.signer, team: signed?.team, verdict: .notarized)
        #expect(signature.developer == "Example Ltd")
    }

    @Test func `the verdict is Gatekeeper's own source`() {
        #expect(InstallerSignature.verdict(status: 0, assessment: "x: accepted\nsource=Notarized Developer ID")
            == .notarized)
        #expect(InstallerSignature.verdict(status: 3, assessment: "x: rejected\nsource=no usable signature")
            == .unsigned)
        #expect(InstallerSignature.verdict(status: 3, assessment: "x: rejected\nsource=Unnotarized Developer ID")
            == .notNotarized)
        #expect(InstallerSignature.verdict(status: 0, assessment: "x: accepted\nsource=Apple System") == .apple)
        #expect(InstallerSignature.verdict(status: 1, assessment: "") == .unknown(nil))
    }

    // MARK: - Layout

    /// A payload is thousands of paths; a person names a handful of things.
    @Test func `paths reduce to the outermost thing the installer creates`() {
        let listing = """
        .\t40755\t
        ./Applications\t40755\t
        ./Applications/Demo.app\t40755\t
        ./Applications/Demo.app/Contents/Info.plist\t100644\t494
        ./Applications/Demo.app/Contents/MacOS/Demo\t100755\t1000
        ./Applications/._Demo.app\t40755\t0
        ./Library\t40755\t
        ./Library/LaunchDaemons\t40755\t
        ./Library/LaunchDaemons/com.example.demo.helper.plist\t100644\t85
        ./Library/Application Support\t40755\t
        ./Library/Application Support/Example\t40755\t
        ./Library/Application Support/Example/Demo\t40755\t
        ./Library/Application Support/Example/Demo/data.bin\t100644\t20
        ./Library/Application Support/Existing.txt\t100644\t7
        ./usr/local/bin/demo\t120755\t20
        """
        let entries = InstallerLayout.entries(lsbom: listing, installLocation: "/")
        #expect(!entries.contains { $0.path.contains("._") })
        let onThisMac: Set = [
            "/Applications", "/Library", "/Library/LaunchDaemons", "/Library/Application Support",
            "/Library/Application Support/Existing.txt", "/usr", "/usr/local", "/usr/local/bin"
        ]
        let roots = InstallerLayout.roots(of: entries) { onThisMac.contains($0) }
        #expect(roots.map(\.path) == [
            "/Applications/Demo.app", "/Library/LaunchDaemons/com.example.demo.helper.plist",
            "/Library/Application Support/Example", "/Library/Application Support/Existing.txt",
            "/usr/local/bin/demo"
        ])
        #expect(roots.first?.bytes == 1494)
        #expect(roots.first { $0.path.hasSuffix("Existing.txt") }?.exists == true)
        #expect(InstallerLayout.classify("/Library/LaunchDaemons/com.example.demo.helper.plist", isDirectory: false).0
            == .background)
        #expect(InstallerLayout.classify("/usr/local/bin/demo", isDirectory: false).0 == .commandLine)
        #expect(InstallerLayout.classify("/Library/Audio/Plug-Ins/HAL/Demo.driver", isDirectory: true).0
            == .systemExtensions)
        #expect(InstallerLayout.classify("/Library/Application Support/Example", isDirectory: true)
            == (.files, "Folder"))
    }

    @Test func `an install location places the payload`() {
        let entries = InstallerLayout.entries(lsbom: "./Demo.app\t40755\t\n./Demo.app/x\t100644\t3",
                                              installLocation: "/Applications/")
        #expect(entries.map(\.path) == ["/Applications/Demo.app", "/Applications/Demo.app/x"])
    }

    @Test func `what an app carries is read from the paths inside it`() {
        let app = "/Applications/Demo.app"
        let entries = [
            "Library/LaunchDaemons/com.example.job.plist", "Library/LaunchDaemons/resource.txt",
            "Library/LoginItems/Demo Helper.app/Contents/Info.plist",
            "Library/SystemExtensions/com.example.filter.systemextension/Contents/Info.plist",
            "PlugIns/Share.appex/Contents/Info.plist", "Resources/icon.icns"
        ].map { InstallerLayout.Entry(path: app + "/Contents/" + $0, isDirectory: false, bytes: 1) }
        let embedded = InstallerLayout.embedded(in: app, entries: entries)
        #expect(embedded.map(\.what) == ["Background job", "Login item", "System extension", "App extension"])
        #expect(embedded.allSatisfy { $0.source == "Inside Demo.app, registered when it runs" })
    }

    // MARK: - Scripts

    @Test func `a script is described by the commands its text calls`() {
        let script = """
        #!/bin/sh
        # We used to run kextload here.
        /bin/launchctl bootstrap system /Library/LaunchDaemons/com.example.plist
        curl -fsSL https://example.com/extra -o /tmp/extra
        echo "this defaults to nothing"
        defaults write com.example.demo Installed -bool true
        """
        #expect(InstallScriptReading.calls(in: script) == [
            "Starts or stops background jobs", "Downloads files", "Changes settings"
        ])
        #expect(InstallScriptReading.isText(Data("#!/bin/sh\n".utf8)))
        #expect(InstallScriptReading.isText(Data([0xCF, 0xFA, 0xED, 0xFE, 0x00])) == false)
    }

    @Test func `an app's declared permissions are named once each`() {
        let info: [String: Any] = [
            "NSCameraUsageDescription": "x", "NSLocationWhenInUseUsageDescription": "x",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "x", "NSAppleEventsUsageDescription": "x"
        ]
        #expect(DeclaredPermissions.names(in: info) == ["Camera", "Location", "Control other apps"])
        #expect(DeclaredPermissions.updater(inFrameworks: ["Foo.framework", "Sparkle.framework"]) == "Sparkle")
    }

    // MARK: - Disk image refusals

    @Test func `a licence or a password stops a disk image before it mounts`() {
        let facts: [String: Any] = ["Format": "UDZO", "Properties": ["Software License Agreement": true,
                                                                     "Encrypted": false]]
        #expect(InstallerReader.flag("Software License Agreement", in: facts))
        #expect(InstallerReader.flag("Encrypted", in: facts) == false)
    }

    // MARK: - A real package

    /// Built with Apple's own tools for the test, read, and never installed.
    @Test func `a package is read without installing it`() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pkgbuild") else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.buildPackage(in: folder)
        let reader = InstallerReader(installed: [
            "com.example.demo": .init(version: "1.1", path: "/Applications/Demo.app")
        ])
        #expect(InstallerReader.kind(of: package) == .package)
        let preview = try reader.read(package)
        #expect(preview.kind == .package)
        #expect(preview.apps.map(\.name) == ["Demo"])
        #expect(preview.apps.first?.identifier == "com.example.demo")
        #expect(preview.apps.first?.replacesVersion == "1.1")
        let background = preview.items.filter { $0.group == .background }.map(\.path)
        #expect(background.contains("/Library/LaunchDaemons/com.example.demo.helper.plist"))
        #expect(background.contains("/Library/PrivilegedHelperTools/com.example.demo.helper"))
        let embedded = "/Applications/Demo.app/Contents/Library/LaunchDaemons/com.example.demo.job.plist"
        #expect(background.contains(embedded))
        #expect(preview.scripts.map(\.name) == ["postinstall"])
        #expect(preview.scripts.first?.runsAsAdministrator == true)
        #expect(preview.scripts.first?.calls == ["Starts or stops background jobs", "Downloads files"])
        #expect(preview.signature.verdict == .unsigned)
        #expect(preview.signature.signer == nil)
        // Nothing was placed on this Mac.
        #expect(!FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.example.demo.helper.plist"))
    }

    @Test func `anything else is refused by what it is, not what it is called`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brim-\(UUID().uuidString).pkg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a package".utf8).write(to: file)
        #expect(throws: InstallerReadError.notAnInstaller) { try InstallerReader(installed: [:]).read(file) }
    }

    static func buildPackage(in folder: URL) throws -> URL {
        let root = folder.appendingPathComponent("root")
        let app = root.appendingPathComponent("Applications/Demo.app/Contents")
        let manager = FileManager.default
        for path in ["MacOS", "Library/LaunchDaemons"] {
            try manager.createDirectory(at: app.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: root.appendingPathComponent("Library/LaunchDaemons"),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Library/PrivilegedHelperTools"),
                                    withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.demo", "CFBundleName": "Demo", "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "12", "CFBundleExecutable": "Demo", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("MacOS/Demo"))
        let job = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.demo.job"],
                                                     format: .xml, options: 0)
        try job.write(to: app.appendingPathComponent("Library/LaunchDaemons/com.example.demo.job.plist"))
        try job.write(to: root.appendingPathComponent("Library/LaunchDaemons/com.example.demo.helper.plist"))
        let helper = root.appendingPathComponent("Library/PrivilegedHelperTools/com.example.demo.helper")
        try Data("x".utf8).write(to: helper)
        let scripts = folder.appendingPathComponent("scripts")
        try manager.createDirectory(at: scripts, withIntermediateDirectories: true)
        let postinstall = scripts.appendingPathComponent("postinstall")
        try Data("""
        #!/bin/sh
        /bin/launchctl bootstrap system /Library/LaunchDaemons/com.example.demo.helper.plist
        /usr/bin/curl -fsSL https://example.com/extra -o /tmp/extra
        exit 0
        """.utf8).write(to: postinstall)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postinstall.path)
        let component = folder.appendingPathComponent("component.pkg")
        let product = folder.appendingPathComponent("Demo.pkg")
        _ = try #require(ToolOutput.run("/usr/bin/pkgbuild", [
            "--root", root.path, "--identifier", "com.example.demo.pkg", "--version", "1.2",
            "--scripts", scripts.path, "--install-location", "/", component.path
        ], timeout: 60).flatMap { $0.status == 0 ? $0 : nil })
        _ = try #require(ToolOutput.run("/usr/bin/productbuild", ["--package", component.path, product.path],
                                        timeout: 60).flatMap { $0.status == 0 ? $0 : nil })
        return product
    }
}
