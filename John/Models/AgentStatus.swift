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

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
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