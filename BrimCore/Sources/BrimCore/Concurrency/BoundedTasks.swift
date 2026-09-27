import Foundation

/// Structured parallel reads with deterministic output and bounded resource use.
public enum BoundedTasks {
    public static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int = 4,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results: [(Int, Output)] = []
            func enqueue(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    try Task.checkCancellation()
                    return try await (index, operation(input))
                }
            }
            while next < min(max(1, limit), inputs.count) {
                enqueue(next)
                next += 1
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                results.append(result)
                if next < inputs.count {
                    enqueue(next)
                    next += 1
                }
            }
            try Task.checkCancellation()
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
