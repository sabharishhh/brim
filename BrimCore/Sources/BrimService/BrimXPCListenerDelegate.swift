import Foundation
import BrimProtocol
import BrimService
import BrimCore

public final class BrimXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let server: BrimXPCServer

    private let requireCodeSigning: Bool

    public init(service: BrimServiceProtocol, requireCodeSigning: Bool = true) {
        self.server = BrimXPCServer(service: service)
        self.requireCodeSigning = requireCodeSigning
        super.init()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if requireCodeSigning {
            MutualAuthentication.secure(newConnection)
        }
        
        newConnection.exportedInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        newConnection.exportedObject = server
        newConnection.resume()
        return true
    }
}
