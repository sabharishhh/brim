// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrimCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "BrimCore", targets: ["BrimCore"]),
        .library(name: "BrimScanShim", targets: ["BrimScanShim"]),
        .library(name: "BrimScan", targets: ["BrimScan"]),
        .library(name: "BrimIndex", targets: ["BrimIndex"]),
        .library(name: "BrimOps", targets: ["BrimOps"]),
        .library(name: "BrimProtocol", targets: ["BrimProtocol"]),
        .library(name: "BrimService", targets: ["BrimService"]),
        .library(name: "BrimPrivileged", targets: ["BrimPrivileged"]),
        .library(name: "BrimUI", targets: ["BrimUI"]),
        .executable(name: "BrimJobHelper", targets: ["BrimJobHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "BrimCore"),
        .target(name: "BrimScanShim"),
        .target(name: "BrimScan", dependencies: ["BrimScanShim", "BrimCore", "BrimOps"]),
        .target(name: "BrimIndex", dependencies: [
            "BrimCore",
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .target(name: "BrimOps", dependencies: ["BrimScanShim"]),
        .target(name: "BrimProtocol", dependencies: ["BrimCore"]),
        .target(name: "BrimService", dependencies: ["BrimIndex", "BrimProtocol", "BrimScan", "BrimCore", "BrimOps"]),
        // Deliberately depends on nothing. A root daemon should be small
        // enough to read in one sitting.
        .target(name: "BrimPrivileged"),
        .target(name: "BrimUI", dependencies: ["BrimProtocol", "BrimCore", "BrimService", "BrimPrivileged"]),
        
        .executableTarget(name: "BrimJobHelper", dependencies: ["BrimPrivileged"]),
        
        // Tests
        .target(name: "BrimFixtures", dependencies: ["BrimCore"], path: "Tests/BrimFixtures", resources: [
            .copy("Manifests")
        ]),
        .testTarget(name: "BrimCoreTests", dependencies: ["BrimCore", "BrimScan", "BrimFixtures"]),
        .testTarget(name: "BrimIndexTests", dependencies: ["BrimIndex", "BrimFixtures"]),
        .testTarget(name: "BrimSecurityTests", dependencies: ["BrimService", "BrimPrivileged", "BrimFixtures"]),
        .testTarget(name: "BrimGoldenTests", dependencies: ["BrimCore", "BrimFixtures"]),
        .testTarget(name: "BrimUITests", dependencies: ["BrimUI", "BrimCore", "BrimProtocol"]),
        // Exercises the real machine. Opt-in via BRIM_REAL_ENV=1; skips otherwise.
        .testTarget(name: "BrimRealEnvironmentTests", dependencies: ["BrimService", "BrimCore", "BrimProtocol", "BrimScan", "BrimOps"]),
    ]
)
