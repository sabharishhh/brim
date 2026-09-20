import Foundation
import Darwin

let tempDir = FileManager.default.temporaryDirectory.path
let resolvedPath = URL(fileURLWithPath: tempDir).resolvingSymlinksInPath().path
print("tempDir:", tempDir)
print("resolvedPath:", resolvedPath)

let components = resolvedPath.split(separator: "/").map { String($0) }.filter { !$0.isEmpty && $0 != "." }
print("components:", components)

var currentFd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
print("root fd:", currentFd)
for component in components {
    var nextFd: Int32 = -1
    var openErrno: Int32 = 0
    component.withCString { cStr in
        nextFd = openat(currentFd, cStr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        openErrno = errno
    }
    if nextFd < 0 {
        print("Failed on component", component, "errno:", openErrno)
        break
    }
    close(currentFd)
    currentFd = nextFd
}
print("final fd:", currentFd)
