import BrimCore
@testable import BrimScan
import Foundation
import Testing

struct HomebrewOwnershipTests {
    @Test func `cask records identify the selected path rather than another copy`() throws {
        let fixture = try BrewFixture()
        defer { fixture.remove() }
        let target = fixture.folder.appendingPathComponent("Custom Apps/Renamed.app")
        try fixture.install("sample", target: target)
        let scanner = UpdateSourceScanner(homebrewPrefixes: [fixture.prefix.path])
        let inventory = scanner.installedCaskInventory()
        let installation = try #require(UpdateSourceScanner.matchingInstallation(at: target, among: inventory))
        #expect(installation.token == "sample")
        #expect(installation.applicationPath == target.path)
        #expect(installation.manualCommand == "'\(fixture.prefix.path)/bin/brew' uninstall --cask sample")
        #expect(installation.explanation.contains("record remains"))
        let copy = fixture.folder.appendingPathComponent("Downloads/Renamed.app")
        #expect(UpdateSourceScanner.matchingInstallation(at: copy, among: inventory) == nil)
        let decoded = try JSONDecoder().decode(HomebrewInstallation.self, from: JSONEncoder().encode(installation))
        #expect(decoded == installation)
    }

    @Test func `ambiguous or incomplete cask records refuse attribution`() throws {
        let fixture = try BrewFixture()
        defer { fixture.remove() }
        let target = fixture.folder.appendingPathComponent("Applications/Sample.app")
        try fixture.install("sample", target: target)
        try fixture.install("other", target: target)
        let scanner = UpdateSourceScanner(homebrewPrefixes: [fixture.prefix.path])
        let ambiguous = scanner.installedCaskInventory()
        #expect(UpdateSourceScanner.matchingInstallation(at: target, among: ambiguous) == nil)
        #expect(UpdateSourceScanner.ownership(at: target, among: ambiguous).completeness.isComplete == false)
        let receipt = fixture.prefix.appendingPathComponent("Caskroom/other/.metadata/INSTALL_RECEIPT.json")
        try Data("malformed".utf8).write(to: receipt)
        let partial = scanner.installedCaskInventory()
        #expect(partial.completeness.unreadable.contains(receipt.path))
        #expect(UpdateSourceScanner.matchingInstallation(at: target, among: partial) == nil)
        let expired = scanner.installedCaskInventory(budget: ScanBudget(total: -1))
        #expect(expired.completeness.timedOut.isEmpty == false)
    }

    @Test func `only recorded current-version app links prove ownership`() throws {
        let fixture = try BrewFixture()
        defer { fixture.remove() }
        let target = fixture.folder.appendingPathComponent("Applications/Sample.app")
        try fixture.install("sample", target: target)
        let stale = fixture.prefix.appendingPathComponent("Caskroom/sample/0.9/Old.app")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: stale,
            withDestinationURL: fixture.folder.appendingPathComponent("Old.app")
        )
        let unrecorded = fixture.prefix.appendingPathComponent("Caskroom/sample/1.0/Other.app")
        try FileManager.default.createSymbolicLink(
            at: unrecorded,
            withDestinationURL: fixture.folder.appendingPathComponent("Other.app")
        )
        let inventory = UpdateSourceScanner(homebrewPrefixes: [fixture.prefix.path]).installedCaskInventory()
        #expect(inventory.installations.count == 1)
        #expect(inventory.installations.first?.applicationPath == target.path)
        for token in ["--force", "sample;rm", "sample\nother", "tap/sample", "sample $(id)"] {
            #expect(HomebrewInstallation(token: token, applicationPath: target.path, receiptPath: "/receipt") == nil)
        }
        let misplaced = try #require(HomebrewInstallation(token: "sample", applicationPath: target.path,
                                                          receiptPath: fixture.prefix
                                                              .appendingPathComponent("receipt.json").path))
        #expect(misplaced.manualCommand == nil)
        try FileManager.default.removeItem(at: fixture.prefix.appendingPathComponent("bin/brew"))
        #expect(inventory.installations.first?.manualCommand == nil)
    }
}

private struct BrewFixture {
    let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("brim-brew-owner-\(UUID().uuidString)")
    var prefix: URL {
        folder.appendingPathComponent("homebrew")
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = prefix.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    func install(_ token: String, target: URL) throws {
        let cask = prefix.appendingPathComponent("Caskroom/" + token)
        let receipt = cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["source": ["version": "1.0"],
                                                    "uninstall_artifacts": [["app": ["Original.app"]]]])
            .write(to: receipt)
        let link = cask.appendingPathComponent("1.0/Original.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }
}
