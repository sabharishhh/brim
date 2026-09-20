enum ExecutionPhase: Int, Comparable {
    case auxiliary = 0
    case launchd = 1
    case appBundle = 2
    static func < (lhs: ExecutionPhase, rhs: ExecutionPhase) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
struct Step {
    let target: String
    let executionPhase: ExecutionPhase
    let index: Int
}
let steps = [
    Step(target: "com.brim.helper", executionPhase: .auxiliary, index: 0),
    Step(target: "SandboxedApp.app", executionPhase: .appBundle, index: 1)
]
let sortedSteps = steps.sorted { a, b in
    if a.executionPhase != b.executionPhase {
        return a.executionPhase > b.executionPhase
    }
    return a.index > b.index
}
for s in sortedSteps {
    print(s.target)
}
