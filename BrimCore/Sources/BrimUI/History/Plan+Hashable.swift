import Foundation
import BrimCore

extension Plan: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(planId)
    }
}
