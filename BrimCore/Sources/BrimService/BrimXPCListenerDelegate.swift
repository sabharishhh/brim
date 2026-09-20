import Foundation
import BrimProtocol
import BrimService
import BrimCore

public final class BrimXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let server: BrimXPCServer

    public init(service: BrimServiceProtocol) {
        self.server = BrimXPCServer(service: service)
        super.init()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        newConnection.exportedObject = server
        newConnection.resume()
        return true
    }
}
