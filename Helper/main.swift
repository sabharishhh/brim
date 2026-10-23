// The administrator process's entry point for the Xcode target. The code
// lives in `BrimPrivileged`, covered by the package's tests; an Xcode
// command line tool target needs its own `main.swift`.
import Foundation
import BrimPrivileged

BrimJobHelperDaemon.run()
