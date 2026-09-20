import Foundation
import Combine
import SwiftUI
import BrimProtocol
import BrimCore

public enum FindingConfidence: Double {
    case guaranteed = 1.0
    case high = 0.8
    case heuristic = 0.4
}

public struct Finding: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let category: String
    public let path: String
    public let byteSize: Int64
    public let confidence: FindingConfidence
    public let leftover: Leftover // Keep a reference to the real data
    
    public var rankScore: Double {
        return confidence.rawValue * Double(byteSize)
    }

    public init(title: String, category: String, path: String, byteSize: Int64, confidence: FindingConfidence, leftover: Leftover) {
        self.title = title
        self.category = category
        self.path = path
        self.byteSize = byteSize
        self.confidence = confidence
        self.leftover = leftover
    }
}

@MainActor
public class ReviewQueueViewModel: ObservableObject {
    @Published public var findings: [Finding] = []
    @Published public var totalCount: Int = 0
    @Published public var totalBytes: Int64 = 0
    @Published public var isPopulating = false
    @Published public var errorMessage: String?

    public init() {}
    
    /// How many findings are published before the table is refreshed. Each
    /// publish re-sorts and reloads the whole `NSTableView`, so doing it per
    /// item makes a few hundred leftovers quadratic.
    private static let batchSize = 25

    public func populateProgressively(service: any BrimServiceProtocol) async {
        isPopulating = true
        defer { isPopulating = false }

        findings = []
        totalCount = 0
        totalBytes = 0
        errorMessage = nil

        do {
            let leftovers = try await service.leftovers()
            var batch: [Finding] = []

            for leftover in leftovers {
                let title = leftover.potentialOwner?.name ?? leftover.url.lastPathComponent
                let categoryStr = leftover.category == .orphaned ? "Orphaned App" : "Unclaimed Leftover"
                let confidence: FindingConfidence = leftover.category == .orphaned ? .guaranteed : .heuristic

                batch.append(Finding(
                    title: title,
                    category: categoryStr,
                    path: leftover.url.path,
                    byteSize: leftover.size,
                    confidence: confidence,
                    leftover: leftover
                ))

                if batch.count >= Self.batchSize {
                    addFindings(batch)
                    batch.removeAll(keepingCapacity: true)
                    // Let the table draw what we have so far.
                    await Task.yield()
                }
            }

            if !batch.isEmpty {
                addFindings(batch)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addFindings(_ newFindings: [Finding]) {
        findings.append(contentsOf: newFindings)
        findings.sort { $0.rankScore > $1.rankScore }
        totalCount = findings.count
        totalBytes += newFindings.reduce(0) { $0 + $1.byteSize }
    }
    
    public func removeItems(with ids: Set<UUID>) {
        let toRemove = findings.filter { ids.contains($0.id) }
        findings.removeAll { ids.contains($0.id) }
        totalCount = findings.count
        for item in toRemove {
            totalBytes -= item.byteSize
        }
    }
}
