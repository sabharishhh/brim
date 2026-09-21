// The privileged daemon's entry point for the Xcode target.
//
// The implementation lives in BrimJobHelperCore so that the same code is
// covered by the package's tests. This file exists because an Xcode
// command line tool target needs a main.swift of its own.
import Foundation
import BrimPrivileged

BrimJobHelperDaemon.run()
