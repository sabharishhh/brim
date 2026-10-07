import Foundation

/// A path as the views show it, with the home folder written as `~`.
///
/// Five views each carried a copy that compared the start of the path with
/// the home folder as text, so another account's `/Users/ann2` read as `~2`
/// to someone called ann. Foundation's abbreviation compares whole folders.
enum PathText {
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
