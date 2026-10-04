import Foundation

extension Planner {
    /// Look up path components instead of comparing every selected item.
    static func hasAncestor(of path: String, in roots: Set<String>) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "/" {
            if roots.contains(parent) {
                return true
            }
            let next = (parent as NSString).deletingLastPathComponent
            guard next != parent else { break }
            parent = next
        }
        return false
    }
}
