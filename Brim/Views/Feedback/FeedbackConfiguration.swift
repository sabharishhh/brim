import BrimUI
import Foundation

enum FeedbackConfiguration {
    @MainActor static func makeModel() -> FeedbackModel {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "BrimFeedbackEndpoint") as? String,
              !address.isEmpty else { return FeedbackModel() }
        guard let endpoint = URL(string: address) else {
            return FeedbackModel(send: { _ in throw FeedbackDeliveryError.invalidEndpoint })
        }
        return FeedbackModel(send: FeedbackDelivery.relay(endpoint: endpoint))
    }
}
