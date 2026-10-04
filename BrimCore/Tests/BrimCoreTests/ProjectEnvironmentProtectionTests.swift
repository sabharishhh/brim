import BrimCore
@testable import BrimScan
import Foundation
import Testing

struct ProjectEnvironmentProtectionTests {
    @Test(arguments: [".venv", "venv"])
    func linkedEnvironmentsProtectChildrenAliasesAndProjectParents(_ entryName: String) throws {
        let fixture = try EnvironmentProtectionFixture()
        defer { fixture.remove() }
        let project = try fixture.folder("Projects/Mixed")
        try Data("[project]".utf8).write(to: project.appendingPathComponent("pyproject.toml"))
        try Data("[package]".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        let environment = try fixture.folder("Environments/Shared")
        try Data("home = /usr/bin".utf8).write(to: environment.appendingPathComponent("pyvenv.cfg"))
        let contents = try fixture.folder("Environments/Shared/lib/python/site-packages/local")
        try Data("custom".utf8).write(to: contents.appendingPathComponent("package.py"))
        let entry = project.appendingPathComponent(entryName)
        let alias = fixture.home.appendingPathComponent("environment-alias")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: environment)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: environment)
        let child = "lib/python/site-packages/local/package.py"
        let targets = [entry, entry.appendingPathComponent(child), alias.appendingPathComponent(child),
                       environment.appendingPathComponent(child), project]
        for target in targets {
            #expect(ProjectBuildScanner.classification(at: target, home: fixture.home) == .stateful)
        }
        let output = try fixture.folder("Projects/Mixed/target")
        #expect(ProjectBuildScanner.classification(at: output, home: fixture.home) == .rebuildableOutput)
        #expect(ProjectBuildScanner.classification(
            at: output.appendingPathComponent("child"), home: fixture.home
        ) == nil)
    }

    @Test func ordinaryTargetsAndFileUrlBoundariesFinishWithoutEnvironmentEvidence() throws {
        let fixture = try EnvironmentProtectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.folder("ordinary/nested")
        let file = directory.appendingPathComponent("note.txt")
        try Data("ordinary".utf8).write(to: file)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let emptyRelative = URL(fileURLWithPath: "", isDirectory: true, relativeTo: root)
        let emptyFile = try #require(URL(string: "file:"))
        for target in [file, directory, root, emptyRelative, emptyFile] {
            #expect(ProjectBuildScanner.classification(at: target, home: fixture.home) == nil)
        }
        #expect(ProjectBuildScanner.classification(at: root, home: root) == nil)
        let environment = try fixture.folder("standalone-environment")
        try Data("home = /usr/bin".utf8).write(to: environment.appendingPathComponent("pyvenv.cfg"))
        let environmentFile = environment.appendingPathComponent("package.py")
        try Data("local".utf8).write(to: environmentFile)
        #expect(ProjectBuildScanner.classification(at: environmentFile, home: fixture.home) == .stateful)
    }

    @Test func protectedEnvironmentEntryDoesNotNeedToRemainADirectory() throws {
        let fixture = try EnvironmentProtectionFixture()
        defer { fixture.remove() }
        let project = try fixture.folder("Projects/Python")
        try Data().write(to: project.appendingPathComponent("requirements.txt"))
        let entry = project.appendingPathComponent(".venv")
        try Data("replaced".utf8).write(to: entry)
        #expect(ProjectBuildScanner.classification(at: entry, home: fixture.home) == .stateful)
        #expect(ProjectBuildScanner.classification(at: project, home: fixture.home) == .stateful)
        let unrelated = try fixture.folder("Projects/Unrelated/venv")
        #expect(ProjectBuildScanner.classification(at: unrelated, home: fixture.home) == nil)
    }
}

struct MixedProjectCoverageTests {
    @Test func allProvenLanguagesAppearOnceAndStatefulEnvironmentsStayProtected() throws {
        let fixture = try EnvironmentProtectionFixture()
        defer { fixture.remove() }
        let project = try fixture.folder("Projects/Mixed")
        let names = ["Cargo.toml", "Package.swift", "package.json", "pyproject.toml", "pom.xml"]
        let markers = names.map { project.appendingPathComponent($0) }
        for marker in markers {
            let content = marker.lastPathComponent == "package.json"
                ? "{\"devDependencies\":{\"next\":\"15\"}}" : "project marker"
            try Data(content.utf8).write(to: marker)
        }
        try Data().write(to: project.appendingPathComponent("package-lock.json"))
        for name in ["target", ".build", "node_modules", ".next", ".venv"] {
            let artifact = try fixture.folder("Projects/Mixed/" + name)
            try Data("contents".utf8).write(to: artifact.appendingPathComponent("output"))
        }
        let scanner = ProjectBuildScanner(search: { _, _ in markers + markers })
        let rows = scanner.discover(home: fixture.home)
        #expect(rows.count == 5)
        #expect(Set(rows.map(\.url.lastPathComponent)) == ["target", ".build", "node_modules", ".next", ".venv"])
        #expect(rows.first { $0.url.lastPathComponent == "node_modules" }?.cost == .restored)
        #expect(rows.first { $0.url.lastPathComponent == ".venv" }?.cost == .configured)
        #expect(ProjectBuildScanner.classification(at: project, home: fixture.home) == .stateful)
        #expect(ProjectBuildScanner.classification(at: project.appendingPathComponent("target"),
                                                   home: fixture.home) == .rebuildableOutput)
    }

    @Test func matchingAnotherLanguageDoesNotRelaxDependencyOrFrameworkProof() throws {
        let fixture = try EnvironmentProtectionFixture()
        defer { fixture.remove() }
        let project = try fixture.folder("Projects/Mixed")
        try Data().write(to: project.appendingPathComponent("Cargo.toml"))
        let node = project.appendingPathComponent("package.json")
        try Data("{}".utf8).write(to: node)
        for name in ["target", "node_modules", ".next"] {
            _ = try fixture.folder("Projects/Mixed/" + name)
        }
        let scanner = ProjectBuildScanner(search: { _, _ in [node] })
        #expect(scanner.discover(home: fixture.home).map(\.url.lastPathComponent) == ["target"])
        #expect(ProjectBuildScanner.classification(at: project.appendingPathComponent("node_modules"),
                                                   home: fixture.home) == nil)
        #expect(ProjectBuildScanner.classification(at: project.appendingPathComponent(".next"),
                                                   home: fixture.home) == nil)
    }
}

private struct EnvironmentProtectionFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("EnvironmentProtection-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func folder(_ path: String) throws -> URL {
        let folder = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
