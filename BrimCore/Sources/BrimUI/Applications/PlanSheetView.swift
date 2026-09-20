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
                    Text(ByteCountFormatter.string(fromByteCount: step.expectedBytes, countStyle: .file))
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
                
                Text("Recovered \(ByteCountFormatter.string(fromByteCount: result.recoveredBytes, countStyle: .file))")
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
                // 1. Request Approval
                // A real app would prompt with Touch ID here or local authentication.
                try await service.requestApproval(planId: plan.planId, requesterIdentity: identity.bundleID ?? "unknown")
                
                // KNOWN: mintTokenForTest is a placeholder for the human-approval minting path.
                // This bypasses the protocol boundary and is flagged as C-1 in the pre-M2 gate audit.
                // M2 (T-2.1) will replace this with proper TokenStore injection into the UI layer,
                // so the UI can call tokenStore.mintToken() directly upon user confirmation, without
                // going through BrimServiceProtocol at all.
                guard let concreteService = service as? BrimService else {
                    throw NSError(domain: "UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot mint token without concrete service"])
                }
                
                let hash = try plan.contentHash()
                let token = await concreteService.tokenStore.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: identity.bundleID ?? "unknown")
                
                // 2. Apply
                try await service.apply(planId: plan.planId, token: token)
                
                // 3. Verify
                let v = try await service.verify(planId: plan.planId)
                self.result = v
                self.executionState = .done
            } catch {
                self.errorMsg = error.localizedDescription
                self.executionState = .done
            }
        }
    }
}
