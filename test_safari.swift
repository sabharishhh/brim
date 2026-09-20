import Foundation
let fm = FileManager.default
let path = "/Users/\(NSUserName())/Library/Containers/com.apple.Safari"
print(path)
var isDir: ObjCBool = false
let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
print("Exists: \(exists), isDir: \(isDir.boolValue)")
