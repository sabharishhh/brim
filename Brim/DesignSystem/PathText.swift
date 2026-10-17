import Foundation

/// A path with the home folder written as `~`. Foundation compares whole
/// folders, so `/Users/ann2` is not shortened for a user called ann.
enum PathText {
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
