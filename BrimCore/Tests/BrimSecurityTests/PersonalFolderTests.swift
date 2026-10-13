@testable import BrimCore
import Foundation
import Testing

/// An app's `product.json` named `.ssh` as its data folder, a declaration
/// is Tier B and Tier B is ticked, and nothing protected the person's keys,
/// their Documents or their home folder itself. These hold both halves: the
/// declaration is not believed, and the paths are never removable anyway.
struct PersonalFolderTests {
    private let root = URL(fileURLWithPath: "/private/tmp/brim-personal-fixture")

    private var checker: SafetyChecker {
        SafetyChecker(root: FileSystemRoot(rootURL: root, userName: "tester"),
                      brimAppURL: URL(fileURLWithPath: "/Applications/Brim.app"))
    }

    private func home(_ path: String) -> URL {
        root.appendingPathComponent("Users/tester").appendingPathComponent(path)
    }

    @Test func `credentials and the person's own folders are never removable`() {
        for path in ["", ".ssh", ".ssh/id_ed25519", ".aws/credentials", ".gnupg", "Documents", "Desktop",
                     "Downloads", "Library", "Library/Keychains/login.keychain-db", "Library/Application Support",
                     ".config", ".local"] {
            #expect(!checker.isSafeToRemove(url: home(path)), "\(path) was removable")
        }
        #expect(!checker.isSafeToRemove(url: root.appendingPathComponent("Users")))
        #expect(!checker.isSafeToRemove(url: root.appendingPathComponent("Users/Shared")))
    }

    @Test func `an app's own data inside those folders still is`() {
        for path in ["Library/Application Support/Demo", "Library/Caches/com.example.demo", ".vscode",
                     ".config/demo", ".local/share/demo", "Documents/Project/node_modules"] {
            #expect(checker.isSafeToRemove(url: home(path)), "\(path) was refused")
        }
    }

    private func declared(_ product: String) throws -> [String] {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Demo-\(UUID().uuidString).app")
        let file = bundle.appendingPathComponent("Contents/Resources/app/product.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data(product.utf8).write(to: file)
        return BundleSurfaceReader.declaredHomeFolders(of: bundle)
    }

    @Test func `a declared folder must name the product and never a shared one`() throws {
        #expect(try declared(#"{"dataFolderName": ".vscode", "applicationName": "code", "urlProtocol": "vscode"}"#)
            == [".vscode"])
        #expect(try declared(#"{"dataFolderName": ".cursor", "applicationName": "cursor"}"#) == [".cursor"])
        #expect(try declared(#"{"dataFolderName": ".ssh", "applicationName": "ssh"}"#).isEmpty)
        #expect(try declared(#"{"dataFolderName": ".config", "applicationName": "config"}"#).isEmpty)
        #expect(try declared(#"{"dataFolderName": ".kube", "applicationName": "evil"}"#).isEmpty)
        #expect(try declared(#"{"dataFolderName": ".evil"}"#).isEmpty)
    }
}
