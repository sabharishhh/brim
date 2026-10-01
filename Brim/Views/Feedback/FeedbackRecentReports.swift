import BrimUI
import SwiftUI

struct FeedbackRecentReports: View {
    let receipts: [FeedbackReceipt]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent reports").font(.headline)
            ForEach(receipts.prefix(3)) { receipt in
                Link(destination: receipt.url) {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text(receipt.title).lineLimit(1)
                        Spacer()
                        Text("#\(receipt.number)").foregroundStyle(Palette.inkSecondary)
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(12)
                    .background(Palette.surface, in: .rect(cornerRadius: Metrics.rowRadius))
                }
            }
        }
    }
}
