import BrimUI

extension FeedbackKind {
    var symbol: String {
        switch self {
        case .bug: "ladybug"
        case .feature: "lightbulb"
        case .general: "bubble.left.and.bubble.right"
        }
    }

    var subtitle: String {
        switch self {
        case .bug: "Something isn't working"
        case .feature: "An idea for Brim"
        case .general: "Anything else on your mind"
        }
    }

    var descriptionPrompt: String {
        switch self {
        case .bug: "What happened? Tell us what you were doing and what went wrong."
        case .feature: "What would you like Brim to do? Tell us how it would help."
        case .general: "What would you like us to know?"
        }
    }
}
