import BrimCore
import Foundation

/// A directory listing and its gaps, under the current search deadline.
struct DirectorySearch {
    let budget: ScanBudget
    var unreadable: [String] = []
    var timedOut: [String] = []

    var completeness: ScanCompleteness {
        ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
    }

    mutating func canContinue(at url: URL) -> Bool {
        guard !budget.hasRunOut else { timedOut.append(url.path); return false }
        return true
    }

    mutating func entries(_ directory: URL) -> [String] {
        guard canContinue(at: directory) else { return [] }
        let read = DirectoryEntries.read(directory)
        // A probe that finishes after the deadline still leaves a gap.
        guard canContinue(at: directory) else { return [] }
        switch read {
        case let .listed(names): return names
        case .refused: unreadable.append(directory.path); return []
        case .absent: return []
        }
    }
}
