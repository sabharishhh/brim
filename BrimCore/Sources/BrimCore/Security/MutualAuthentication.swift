import Foundation

public struct MutualAuthentication {
    public static func secure(_ connection: NSXPCConnection) {
        #if DEBUG
        connection.setCodeSigningRequirement("identifier \"com.google.Brim\"")
        #else
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"com.google.Brim\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"")
        #endif
    }
}
