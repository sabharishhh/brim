import Foundation

let path = FileManager.default.temporaryDirectory.path
var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
if realpath(path, &buffer) != nil {
    print(String(cString: buffer))
} else {
    print("realpath failed")
}
