import SwiftUI
import BrimProtocol
import BrimCore
import BrimService

public struct PlanSheetView: View {
    let plan: Plan
    let identity: Identity
    @Binding var isPresented: Bool
    
    @SwiftUI.Environment(\.brimService) var service
    
    @State private var executionState: ExecutionState = .reviewing
    @State private var result: VerificationResult?
    @State private var errorMsg: String?
    
    enum ExecutionState {
        case reviewing
        case executing
        case done
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            if executionState == .reviewing {
                planStepsList
            } else if executionState == .executing {
                ProgressView("Executing plan...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if executionState == .done {
                resultView
            }
            
            Divider()
            footerView
        }
        .frame(width: 600, height: 400)
    }
    
    private var headerView: some View {
        HStack {
            Text("Uninstall Plan")
                .font(.headline)
            Spacer()
            Text("\(plan.steps.count) items to remove")
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    private var planStepsList: some View {
        List {
            ForEach(plan.steps, id: \.target) { step in
                HStack {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                    Text(step.target)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(ByteText.short(step.expectedBytes))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var resultView: some View {
        VStack(spacing: 16) {
            if let result = result {
                Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .foregroundColor(result.success ? .green : .yellow)
                
                Text(result.success ? "Uninstall Complete" : "Uninstall Partially Complete")
                    .font(.title)
                
                Text("Recovered \(ByteText.short(result.recoveredBytes))")
                    .font(.headline)
                
                if let reason = result.reason {
                    Text(reason)
                        .foregroundColor(.secondary)
                }
            } else if let err = errorMsg {
                Image(systemName: "xmark.octagon.fill")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .foregroundColor(.red)
                
                Text("Execution Failed")
                    .font(.title)
                
                Text(err)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var footerView: some View {
        HStack {
            if executionState == .done {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(executionState == .executing)
                
                Spacer()
                
                Button("Approve & Execute") {
                    executePlan()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(executionState == .executing)
            }
        }
        .padding()
    }
    
    private func executePlan() {
        executionState = .executing
        Task {
            do {
                BrimClient.shared.service = service
                // The requester is whoever asked for the removal, and that is
                // the person at this window. It used to pass the identifier
                // of the application being removed, falling back to the
                // literal string "unknown", so the ledger recorded the
                // subject as the requester and sometimes recorded nobody.
                let v = try await BrimClient.shared.execute(
                    plan: plan, requesterIdentity: NSUserName()
                )
                self.result = v
                self.executionState = .done
            } catch {
                self.errorMsg = error.localizedDescription
                self.executionState = .done
            }
        }
    }
}
