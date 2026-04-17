import Foundation

enum BackendError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case backendError(String)
    case noContent
    case encodingFailed
    case connectionRefused
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid backend URL"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid response from backend"
        case .backendError(let message): return "Backend error: \(message)"
        case .noContent: return "No content in response"
        case .encodingFailed: return "Failed to encode request"
        case .connectionRefused: return "Backend not running. Start with: cd backend && uvicorn app.main:app --port 8765"
        }
    }
}

struct BackendResponse: Codable {
    let response: String?
    let threadId: String?
    let toolCalls: [ToolCall]?
    let observations: [String]?
    let timestamp: String?
    
    struct ToolCall: Codable {
        let tool: String
        let args: [String: JSONValue]?
        let result: String?
        let timestamp: String?
    }
}

struct JSONValue: Codable {
    let value: Any?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: JSONValue].self) {
            var result: [String: Any?] = [:]
            for (key, val) in dictValue {
                result[key] = val.value
            }
            value = result
        } else {
            value = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else {
            try container.encodeNil()
        }
    }
}

struct ToolInfo: Codable {
    let name: String
    let description: String
    let parameters: [String: JSONValue]?
}

struct HealthResponse: Codable {
    let status: String
    let model: String
    let timestamp: String
}

actor BackendClient {
    static let shared = BackendClient()
    
    private var baseURL: String
    private let session: URLSession
    private var isHealthy = false
    private var webSocketTask: URLSessionWebSocketTask?
    
    private init() {
        let host = UserDefaults.standard.string(forKey: "backend_host") ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: "backend_port")
        let portStr = port == 0 ? "8765" : "\(port)"
        self.baseURL = "http://\(host):\(portStr)"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        print("[BackendClient] Configured to \(self.baseURL)")
    }
    
    func configure(host: String, port: Int) {
        self.baseURL = "http://\(host):\(port)"
        UserDefaults.standard.set(host, forKey: "backend_host")
        UserDefaults.standard.set(port, forKey: "backend_port")
        print("[BackendClient] Configured to \(self.baseURL)")
    }
    
    func getBaseURL() -> String {
        return baseURL
    }
    
    func checkHealth() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/health") else {
            throw BackendError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BackendError.invalidResponse
            }
            
            if httpResponse.statusCode == 200 {
                isHealthy = true
                return true
            }
            
            return false
        } catch {
            isHealthy = false
            throw BackendError.connectionRefused
        }
    }
    
    func sendChat(
        message: String,
        threadId: String = "default"
    ) async throws -> BackendResponse {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw BackendError.invalidURL
        }
        
        let requestBody: [String: Any] = [
            "message": message,
            "thread_id": threadId,
            "stream": false
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw BackendError.encodingFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                throw BackendError.backendError(errorResponse.detail)
            }
            throw BackendError.backendError("HTTP \(httpResponse.statusCode)")
        }
        
        let backendResponse = try JSONDecoder().decode(BackendResponse.self, from: data)
        return backendResponse
    }
    
    func streamChat(
        message: String,
        threadId: String = "default",
        onEvent: @escaping (StreamEvent) -> Void
    ) async throws {
        guard let url = URL(string: "\(baseURL)/api/chat/stream") else {
            throw BackendError.invalidURL
        }
        
        let requestBody: [String: Any] = [
            "message": message,
            "thread_id": threadId,
            "stream": true
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw BackendError.encodingFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        
        let (bytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BackendError.invalidResponse
        }
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            
            let jsonData = String(line.dropFirst(6))
            guard let data = jsonData.data(using: .utf8) else { continue }
            
            if let event = try? JSONDecoder().decode(StreamEvent.self, from: data) {
                onEvent(event)
            }
        }
    }
    
    func listTools() async throws -> [ToolInfo] {
        guard let url = URL(string: "\(baseURL)/api/tools") else {
            throw BackendError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, _) = try await session.data(for: request)
        let tools = try JSONDecoder().decode([ToolInfo].self, from: data)
        return tools
    }
    
    func resetConversation(threadId: String = "default") async throws {
        guard let url = URL(string: "\(baseURL)/api/conversation/reset?thread_id=\(threadId)") else {
            throw BackendError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BackendError.invalidResponse
        }
    }
    
    func speakTTS(text: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/api/tts") else {
            throw BackendError.invalidURL
        }
        
        let requestBody: [String: Any] = ["text": text]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw BackendError.encodingFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let backendError = String(data: data, encoding: .utf8), !backendError.isEmpty {
                throw BackendError.backendError(backendError)
            }
            throw BackendError.invalidResponse
        }

        return data
    }
}

struct StreamEvent: Codable {
    let type: String?
    let node: String?
    let output: OutputData?
    let content: String?
    let accumulated: String?
    
    struct OutputData: Codable {
        let messages: [MessageData]?
        let response: String?
        let final_response: String?
        
        struct MessageData: Codable {
            let type: String?
            let content: String?
        }
    }
}

struct BackendErrorResponse: Codable {
    let detail: String
}

struct WSMessage: Codable {
    let type: String
    let message: String?
    let threadId: String?
    let data: [String: JSONValue]?
    
    enum CodingKeys: String, CodingKey {
        case type, message, threadId = "thread_id", data
    }
}

enum WSMessageType: String {
    case chat
    case ping
    case reset
}

struct WSResponse: Codable {
    let type: String?
    let node: String?
    let content: String?
    let accumulated: String?
    let response: String?
    let message: String?
    let timestamp: String?
    let threadId: String?
    
    enum CodingKeys: String, CodingKey {
        case type, node, content, accumulated, response, message, timestamp
        case threadId = "thread_id"
    }
}

enum WSClientError: LocalizedError {
    case notConnected
    case sendFailed
    case receiveFailed
    case invalidMessage
    case connectionClosed
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .sendFailed: return "Failed to send message"
        case .receiveFailed: return "Failed to receive message"
        case .invalidMessage: return "Invalid message format"
        case .connectionClosed: return "Connection was closed"
        }
    }
}

extension BackendClient {
    func connectWebSocket(threadId: String = "default") async throws {
        guard let url = URL(string: "\(baseURL)/ws/chat/\(threadId)") else {
            throw BackendError.invalidURL
        }
        
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        try await webSocketTask?.send(.string(""))
        print("[WS] Connected to \(threadId)")
    }
    
    func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        print("[WS] Disconnected")
    }
    
    func sendChatWS(message: String, threadId: String = "default", onEvent: @escaping (WSResponse) -> Void) async throws {
        guard let task = webSocketTask else {
            throw WSClientError.notConnected
        }
        
        let wsMessage = WSMessage(type: "chat", message: message, threadId: threadId, data: nil)
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(wsMessage)
        
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BackendError.encodingFailed
        }
        
        try await task.send(.string(jsonString))
        
        try await receiveLoop(threadId: threadId, onEvent: onEvent)
    }
    
    private func receiveLoop(threadId: String, onEvent: @escaping (WSResponse) -> Void) async throws {
        guard let task = webSocketTask else { return }
        
        while true {
            do {
                let message = try await task.receive()
                
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let response = try? JSONDecoder().decode(WSResponse.self, from: data) {
                        onEvent(response)
                        
                        if response.type == "complete" || response.type == "error" {
                            return
                        }
                    }
                case .data(let data):
                    if let response = try? JSONDecoder().decode(WSResponse.self, from: data) {
                        onEvent(response)
                        
                        if response.type == "complete" || response.type == "error" {
                            return
                        }
                    }
                @unknown default:
                    break
                }
            } catch {
                print("[WS] Receive error: \(error)")
                break
            }
        }
    }
    
    func sendPing() async throws {
        guard let task = webSocketTask else {
            throw WSClientError.notConnected
        }
        
        let pingMsg = WSMessage(type: "ping", message: nil, threadId: nil, data: nil)
        let jsonData = try JSONEncoder().encode(pingMsg)
        
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BackendError.encodingFailed
        }
        
        try await task.send(.string(jsonString))
    }
}
