import Foundation
import BrimService
import BrimCore
import BrimIndex


func runHelper() {
    
    do {
        try SelfVerification.verifyCodeSignature()
        let dbURL = URL(fileURLWithPath: "/Library/Application Support/com.google.Brim/brim.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            let dbManager = try DatabaseManager(databaseURL: dbURL)
            try dbManager.checkIntegrity()
        }
    } catch {
        print("BrimHelper tampered! Aborting. \(error)")
        exit(1)
    }


    // 1. Setup Data Stores
    let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
    let brimAppURL = URL(fileURLWithPath: "/Applications/Brim.app") // TODO: detect
    let brimSupportURL = URL(fileURLWithPath: "/Library/Application Support/com.google.Brim")
    
    do {
        try FileManager.default.createDirectory(at: brimSupportURL, withIntermediateDirectories: true)
    } catch {
        print("Failed to create support directory: \(error)")
        exit(1)
    }
    
    let planStoreDir = brimSupportURL.appendingPathComponent("Plans")
    let journalStoreDir = brimSupportURL.appendingPathComponent("Journal")
    
    let service = BrimService(
        root: root,
        brimAppURL: brimAppURL,
        planStoreDirectory: planStoreDir,
        journalStoreDirectory: journalStoreDir
    )
    
    // 2. Setup XPC Listener on the Mach Service
    let listener = NSXPCListener(machServiceName: "com.google.Brim.daemon")
    
    // We require code signing for all incoming connections to the daemon.
    let delegate = BrimXPCListenerDelegate(service: service, requireCodeSigning: true)
    listener.delegate = delegate
    
    // 3. Resume and park the main thread
    listener.resume()
    
    print("BrimHelper daemon started on com.google.Brim.daemon")
    
    // Keep the daemon alive
    RunLoop.main.run()
}

runHelper()
