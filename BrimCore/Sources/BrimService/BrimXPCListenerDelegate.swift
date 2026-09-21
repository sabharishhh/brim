import Foundation
import BrimProtocol
import BrimService
import BrimCore

public final class BrimXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let server: BrimXPCServer
    private let accepting: XPCPeerExpectation

    /// - Parameter accepting: what the far end has to prove it is. There is
    ///   deliberately no default and no boolean: every listener states who
    ///   it will talk to, because the old `requireCodeSigning: false` was
    ///   passed at four of the five call sites and nobody had to think
    ///   about it at any of them.
    public init(service: BrimServiceProtocol, accepting: XPCPeerExpectation) {
        self.server = BrimXPCServer(service: service)
        self.accepting = accepting
        super.init()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Pinned before the interface is exported, and refused outright if
        // the pin did not take. This used to apply the requirement, ignore
        // whether it worked, and return true regardless.
        guard MutualAuthentication.pin(newConnection, to: accepting) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        newConnection.exportedObject = server
        newConnection.resume()
        return true
    }
}
