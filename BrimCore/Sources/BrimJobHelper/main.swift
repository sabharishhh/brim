// The package's copy of the privileged daemon, so `swift build` produces
// one and the tests can reach the same code the application ships.
import BrimPrivileged

BrimJobHelperDaemon.run()
