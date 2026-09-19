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
        .library(name: "BrimHelperCore", targets: ["BrimHelperCore"]),
        .executable(name: "BrimCLI", targets: ["BrimCLI"]),
        .executable(name: "BrimMCP", targets: ["BrimMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "BrimCore"),
        .target(name: "BrimScanShim"),
        .target(name: "BrimScan", dependencies: ["BrimScanShim", "BrimCore"]),
        .target(name: "BrimIndex", dependencies: [
            "BrimCore",
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .target(name: "BrimOps", dependencies: ["BrimScanShim"]),
        .target(name: "BrimProtocol", dependencies: ["BrimCore"]),
        .target(name: "BrimService", dependencies: ["BrimIndex", "BrimProtocol", "BrimScan", "BrimCore", "BrimOps"]),
        .target(name: "BrimHelperCore", dependencies: ["BrimCore", "BrimOps", "BrimProtocol"]),
        
        .executableTarget(name: "BrimCLI", dependencies: ["BrimProtocol"]),
        .executableTarget(name: "BrimMCP", dependencies: ["BrimProtocol"]),
        
        // Tests
        .target(name: "BrimFixtures", dependencies: ["BrimCore"], path: "Tests/BrimFixtures", resources: [
            .copy("Manifests")
        ]),
        .testTarget(name: "BrimCoreTests", dependencies: ["BrimCore", "BrimScan", "BrimFixtures"]),
        .testTarget(name: "BrimIndexTests", dependencies: ["BrimIndex", "BrimFixtures"]),
        .testTarget(name: "BrimSecurityTests", dependencies: ["BrimService", "BrimHelperCore", "BrimFixtures"]),
        .testTarget(name: "BrimGoldenTests", dependencies: ["BrimCore", "BrimFixtures"]),
    ]
)
