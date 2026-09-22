import SwiftUI
import BrimProtocol
import BrimCore

public struct HistoryDetailView: View {
    let entry: Plan
    let onUndo: () -> Void
    
    @SwiftUI.Environment(\.brimService) var service
    @State private var errorMsg: String?
    @State private var isUndoing = false
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Execution Details")
                .font(.largeTitle)
            
            HStack {
                Text("Date:")
                Text(entry.createdAt, style: .date)
                Text(entry.createdAt, style: .time)
            }
            
            // Not every subject has an identifier. Its name is still a fact,
            // where the word "unknown" was not.
            Text("Target: " + (entry.intent.subjectIdentity.bundleID
                               ?? entry.intent.subjectIdentity.name))
            
            Text("Steps")
                .font(.headline)
                .padding(.top)
            
            List(entry.steps, id: \.target) { step in
                HStack {
                    Text(step.target)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(ByteText.short(step.expectedBytes))
                        .foregroundColor(.secondary)
                }
            }
            
            if let errorMsg = errorMsg {
                Text(errorMsg)
                    .foregroundColor(.red)
            }
            
            Button("Undo Action") {
                undoAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isUndoing)
            
            Spacer()
        }
        .padding()
    }
    
    private func undoAction() {
        isUndoing = true
        Task {
            do {
                try await service.undo(planId: entry.planId)
                onUndo()
            } catch {
                self.errorMsg = "Undo failed: \(error.localizedDescription)"
                isUndoing = false
            }
        }
    }
}
