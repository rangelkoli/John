import Foundation

enum AgentStatus: Equatable {
    case idle
    case thinking(String?)
    case waitingForInput
    case error(String)
    case taskCompleted
    
    var isActive: Bool {
        switch self {
        case .thinking, .waitingForInput:
            return true
        case .idle,.error, .taskCompleted:
            return false
        }
    }
    
    var displayText: String? {
        switch self {
        case .thinking(let tool):
            return tool ?? "Thinking..."
        case .waitingForInput:
            return "Waiting for input"
        case .error(let message):
            return message
        case .taskCompleted:
            return "Task completed"
        case .idle:
            return nil
        }
    }
}