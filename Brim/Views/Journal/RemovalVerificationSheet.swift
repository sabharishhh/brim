import BrimCore
import BrimProtocol
import SwiftUI

struct RemovalVerificationSheet: View {
    let result: VerificationResult
    let plan: Plan?
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            RemovalResultView(result: result, plan: plan)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .capsuleAction(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
    }
}
