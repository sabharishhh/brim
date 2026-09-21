
import BrimCore
import BrimIndex

do {
    try SelfVerification.verifyCodeSignature()
    let dbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim/brim.sqlite")
    if FileManager.default.fileExists(atPath: dbURL.path) {
        let dbManager = try DatabaseManager(databaseURL: dbURL)
        try dbManager.checkIntegrity()
    }
} catch {
    print("Self-verification failed: \(error)")
    // exit(1) in production
}

import Foundation
import ArgumentParser
import BrimProtocol
import BrimCore
import BrimService

struct BrimOptions: ParsableArguments {
}


@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct BrimCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brim",
        abstract: "Brim Command Line Interface",
        subcommands: [
            Apps.self,
            FootprintCmd.self,
            PlanCmd.self,
            ApproveRequest.self,
            Apply.self,
            Verify.self,
            History.self,
            LeftoversCmd.self,
            DuplicatesCmd.self,
            EnergyCmd.self,
            DryRunUninstall.self,
            Install.self
        ]
    )
    
    
    
    nonisolated(unsafe) static var sharedListener: NSXPCListener?
    nonisolated(unsafe) static var sharedDelegate: BrimXPCListenerDelegate?
    nonisolated(unsafe) static var sharedClient: BrimXPCClient?
    
    // Shared service accessor
    static func getService() -> BrimServiceProtocol {
        if let client = sharedClient {
            return client
        }
        
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Brim")
        let planDir = appSupport.appendingPathComponent("Plans")
        let journalDir = appSupport.appendingPathComponent("Journals")
        
        try? FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        
        let realService = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planDir, journalStoreDirectory: journalDir)
        
        // An anonymous listener over its own endpoint, inside this
        // process. Two reasons it is here rather than handing back
        // `realService` directly. It exercises the transport the app uses,
        // so the CLI cannot pass on a path the app would fail. And it
        // strips `ApprovalGranting`: a `BrimXPCClient` has no method that
        // mints a token, which is what keeps the CLI unable to approve its
        // own work. Returning the service itself would hand that back.
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, accepting: .sameProcessAnonymous)
        listener.delegate = delegate
        listener.resume()
        
        // Connect client to anonymous listener
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        let client = try! BrimXPCClient(connection: connection, expecting: .sameProcessAnonymous)
        
        sharedListener = listener
        sharedDelegate = delegate
        sharedClient = client
        
        return client
    }
}

/// An error with nothing around it.
///
/// Anything crossing the XPC boundary arrives as an `NSError`, and printing
/// one gives the reader a domain, a code and the same sentence twice. What
/// a person needs from a refusal is the sentence.
struct Refusal: Error, CustomStringConvertible {
    let description: String
    init(_ error: Error) { self.description = error.localizedDescription }
}

// MARK: - Formatters

func outputJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    
    if let data = try? encoder.encode(value),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    } else {
        print("{}")
    }
}

// MARK: - Commands

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apps", abstract: "List installed applications")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let appsURL = await root.url(for: .applications)
        let contents = (try? FileManager.default.contentsOfDirectory(at: appsURL, includingPropertiesForKeys: nil)) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }.map { $0.lastPathComponent }
        
        if json {
            outputJSON(apps)
        } else {
            for app in apps {
                print(app)
            }
        }
    }
}

struct FootprintCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "footprint", abstract: "Calculate footprint for an app")
    @Argument(help: "Bundle ID of the app") var bundleID: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let identity = Identity(bundleID: bundleID, name: bundleID)
        let footprint = try await BrimCLI.getService().inspect(identity: identity)
        if json {
            outputJSON(footprint)
        } else {
            print("Footprint for \(bundleID): \(footprint.totalSizeBytes) bytes logically across \(footprint.items.count) items.")
            print(" - Reclaimable: \(footprint.reclaimableSizeBytes) bytes")
            print(" - Snapshot-Pinned: \(footprint.snapshotPinnedBytes) bytes")
            
            for item in footprint.items {
                let capStr = item.capability == .ok ? "" : " [\(item.capability.rawValue)]"
                print(" - \(item.evidence.url.path) (\(item.sizeBytes) bytes)\(capStr)")
            }
        }
    }
}

struct PlanCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Plan operations", subcommands: [Uninstall.self, Reset.self, Archive.self])
}

extension PlanCmd {
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Create an uninstall plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created uninstall plan \(plan.planId) with \(plan.steps.count) steps.")
            }
        }
    }
    
    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset", abstract: "Create a reset plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let intent = PlanIntent(type: .reset, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created reset plan \(plan.planId) with \(plan.steps.count) steps.")
            }
        }
    }
    
    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "archive", abstract: "Create an archive plan")
        @Argument(help: "Bundle ID of the app") var bundleID: String
        @Argument(help: "Destination directory for the archive") var destination: String
        @OptionGroup var globalOptions: BrimOptions
        @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
        
        mutating func run() async throws {
            let identity = Identity(bundleID: bundleID, name: bundleID)
            let destURL = URL(fileURLWithPath: destination)
            let intent = PlanIntent(type: .archive, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName(), destinationTarget: destURL)
            let plan = try await BrimCLI.getService().plan(intent: intent)
            if json {
                outputJSON(plan)
            } else {
                print("Created archive plan \(plan.planId) with \(plan.steps.count) steps. Destination: \(destination)")
            }
        }
    }
}

struct ApproveRequest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve-request", abstract: "Request approval for a plan")
    @Argument(help: "Plan ID") var planId: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        let receipt = try await BrimCLI.getService().requestApproval(
            planId: uuid, requesterIdentity: NSUserName()
        )

        if json {
            outputJSON(receipt)
        } else {
            print("Approval requested for \(uuid.uuidString).")
            print(receipt.summary)
            print("")
            print("This did not approve anything. Open Brim and confirm the removal there.")
        }
    }
}

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply", abstract: "Apply an approved plan")
    @Argument(help: "Plan ID") var planId: String
    @Option(name: .long, help: "Approval token") var token: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        // Deserialize token
        guard let data = Data(base64Encoded: token),
              let approvalToken = try? JSONDecoder().decode(ApprovalToken.self, from: data) else {
            throw ValidationError("Invalid or unparseable token")
        }
        
        do {
            try await BrimCLI.getService().apply(planId: uuid, token: approvalToken)
        } catch {
            throw Refusal(error)
        }
        
        if json {
            outputJSON(["status": "applied", "planId": uuid.uuidString])
        } else {
            print("Successfully applied plan \(uuid.uuidString).")
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Verify an executed plan")
    @Argument(help: "Plan ID") var planId: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: planId) else {
            throw ValidationError("Invalid UUID")
        }
        
        let result = try await BrimCLI.getService().verify(planId: uuid)
        if json {
            outputJSON(result)
        } else {
            print("Verification for \(uuid.uuidString): \(result.success ? "Success" : "Failure") - \(result.recoveredBytes) bytes recovered.")
        }
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "View execution history")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let history = try await BrimCLI.getService().history()
        if json {
            outputJSON(history)
        } else {
            for plan in history {
                print("Plan \(plan.planId) - \(plan.createdAt)")
            }
        }
    }
}

struct LeftoversCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "leftovers", abstract: "Scan for leftovers and orphans")
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let leftovers = try await BrimCLI.getService().leftovers()
        if json {
            outputJSON(leftovers)
        } else {
            let orphaned = leftovers.filter { $0.category == .orphaned }
            let unclaimed = leftovers.filter { $0.category == .unclaimed }
            
            print("Found \(leftovers.count) potential leftovers.")
            print("\nOrphaned (\(orphaned.count)):")
            for item in orphaned {
                print(" - \(item.url.path) (\(item.size) bytes)")
            }
            
            print("\nUnclaimed (\(unclaimed.count)):")
            for item in unclaimed {
                print(" - \(item.url.path) (\(item.size) bytes)")
            }
        }
    }
}

struct DuplicatesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "duplicates", abstract: "Scan for duplicate files in a directory")
    @Argument(help: "Directory to scan") var path: String
    @OptionGroup var globalOptions: BrimOptions
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        let directoryURL = URL(fileURLWithPath: path)
        let duplicates = try await BrimCLI.getService().scanDuplicates(in: directoryURL)
        
        if json {
            outputJSON(duplicates)
        } else {
            var totalLogical: Int64 = 0
            var totalRecoverable: Int64 = 0
            
            for group in duplicates {
                totalLogical += group.logicalSize
                totalRecoverable += group.recoverableBytes
            }
            
            print("Found \(duplicates.count) duplicate groups.")
            print("Total Logical Size: \(totalLogical) bytes")
            print("Total Recoverable Space: \(totalRecoverable) bytes")
            print("----------------------------------------")
            
            for group in duplicates {
                print("Group (Hash: \(group.hash.prefix(8))..., Size per file: \(group.size) bytes, Recoverable: \(group.recoverableBytes) bytes):")
                for p in group.paths {
                    print("  - \(p)")
                }
            }
        }
    }
}

struct DryRunUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dry-run-uninstall", abstract: "Run the full uninstall pipeline end-to-end against a shadow root")
    @Argument(help: "Bundle ID of the app") var bundleID: String
    @Flag(name: .shortAndLong, help: "Output in JSON format") var json = false
    
    mutating func run() async throws {
        // 1. Get real footprint
        let realService = BrimCLI.getService()
        let identity = Identity(bundleID: bundleID, name: bundleID)
        let footprint = try await realService.inspect(identity: identity)
        
        let paths = footprint.items.map { $0.evidence.url.path }
        
        // 2. Generate shadow root
        let rootURL = URL(fileURLWithPath: "/")
        let realRoot = FileSystemRoot(rootURL: rootURL)
        let generator = ShadowRootGenerator(sourceRoot: realRoot)
        let shadowRoot = try generator.createShadowRoot(copying: paths)
        
        // 3. Create shadow service with ephemeral storage
        let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app")
        let ephemeralBase = shadowRoot.rootURL.appendingPathComponent(".brim_ephemeral")
        let planDir = ephemeralBase.appendingPathComponent("Plans")
        let journalDir = ephemeralBase.appendingPathComponent("Journals")
        try FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: shadowRoot.rootURL)
        }
        
        let shadowService = BrimService(
            root: shadowRoot, brimAppURL: brimAppURL,
            planStoreDirectory: planDir, journalStoreDirectory: journalDir,
            consent: ConsentSource { _ in true }
        )
        
        // 4. Run pipeline
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, requesterKind: "cli", requesterIdentity: NSUserName())
        let plan = try await shadowService.plan(intent: intent)
        
        // The dry run works on a copy of the tree in a temporary directory,
        // so there is nothing here worth interrupting a person for. It still
        // goes through the same gate as everything else, with a consent
        // source that only exists for the shadow tree and is discarded with
        // it.
        try await shadowService.approveAndApply(
            planId: plan.planId, requesterIdentity: NSUserName()
        )
        
        let verification = try await shadowService.verify(planId: plan.planId)
        
        if json {
            outputJSON(verification)
        } else {
            print("Shadow run complete for \(bundleID).")
            print("Target paths successfully mirrored and trashed in \(shadowRoot.rootURL.path)")
            print("Verification result: \(verification.success ? "Success" : "Failure") - \(verification.recoveredBytes) bytes recovered.")
        }
    }
}

import ServiceManagement

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Set up the helper that removes root-owned job files"
    )

    mutating func run() async throws {
        // This used to register `com.google.Brim.daemon`, a full-service
        // root daemon that ran the whole of BrimService as root. It was
        // never built, signed or installed by the application, and it has
        // been deleted. Registering a daemon is also not something a
        // command line tool should do on its own: macOS shows the approval
        // in Login Items, against the application, so the application is
        // where it belongs.
        print("""
        Brim's helper is set up from the app, in the Background section, \
        where it explains what the helper will and will not touch before \
        you approve it.

        It is one approval, in System Settings, and nothing runs at login.
        """)
        throw ExitCode(1)
    }
}

extension AsyncParsableCommand {
    mutating func runAsync() async throws {
        try await self.run()
    }
}

do {
    var command = try BrimCLI.parseAsRoot()
    if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.runAsync()
    } else {
        try command.run()
    }
} catch {
    BrimCLI.exit(withError: error)
}
