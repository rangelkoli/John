import Foundation

enum OpenRouterError: LocalizedError {
    case invalidURL
    case noAPIKey
    case encodingFailed
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case noContent
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .noAPIKey: return "No API key configured"
        case .encodingFailed: return "Failed to encode request"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid response from server"
        case .apiError(let message): return "API error: \(message)"
        case .rateLimited(let retryAfter): 
            if let after = retryAfter {
                return "Rate limited. Retry after \(Int(after)) seconds"
            }
            return "Rate limited. Please wait before retrying"
        case .noContent: return "No content in response"
        }
    }
}

struct OpenRouterResponse: Codable {
    let id: String?
    let choices: [Choice]?
    let error: OpenRouterErrorDetail?
    
    struct Choice: Codable {
        let message: MessageContent?
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    
    struct MessageContent: Codable {
        let role: String?
        let content: String?
    }
    
    struct OpenRouterErrorDetail: Codable {
        let message: String?
        let type: String?
    }
}

actor OpenRouterClient {
    static let shared = OpenRouterClient()
    
    private let baseURL = "https://openrouter.ai/api/v1"
    private let session: URLSession
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 1.0
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    func chatCompletion(
        messages: [Message],
        model: String,
        apiKey: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw OpenRouterError.noAPIKey
        }
        
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw OpenRouterError.invalidURL
        }
        
        let openAIMessages = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
            "stream": false
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw OpenRouterError.encodingFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("John/1.0", forHTTPHeaderField: "X-Title")
        request.httpBody = httpBody
        
        return try await executeWithRetry(request: request, retryCount: 0)
    }
    
    private func executeWithRetry(request: URLRequest, retryCount: Int) async throws -> String {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenRouterError.invalidResponse
            }
            
            if httpResponse.statusCode == 429 {
                let retryAfterString = httpResponse.value(forHTTPHeaderField: "Retry-After")
                let retryAfter = retryAfterString.flatMap { TimeInterval($0) } ?? 60
                throw OpenRouterError.rateLimited(retryAfter: retryAfter)
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorResponse = try? JSONDecoder().decode(OpenRouterResponse.self, from: data)
                let errorMessage = errorResponse?.error?.message 
                    ?? errorResponse?.error?.type
                    ?? "HTTP \(httpResponse.statusCode)"
                throw OpenRouterError.apiError(errorMessage)
            }
            
            let decodedResponse = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            
            guard let content = decodedResponse.choices?.first?.message?.content, !content.isEmpty else {
                if let error = decodedResponse.error {
                    throw OpenRouterError.apiError(error.message ?? error.type ?? "Unknown error")
                }
                throw OpenRouterError.noContent
            }
            
            return content
            
        } catch let error as OpenRouterError {
            if case .rateLimited = error, retryCount < maxRetries {
                let delay = retryDelay * pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await executeWithRetry(request: request, retryCount: retryCount + 1)
            }
            throw error
        } catch {
            if retryCount < maxRetries {
                let delay = retryDelay * pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await executeWithRetry(request: request, retryCount: retryCount + 1)
            }
            throw OpenRouterError.networkError(error)
        }
    }
    
    func streamCompletion(
        messages: [Message],
        model: String,
        apiKey: String,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw OpenRouterError.noAPIKey
        }
        
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw OpenRouterError.invalidURL
        }
        
        let openAIMessages = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
            "stream": true
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw OpenRouterError.encodingFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("John/1.0", forHTTPHeaderField: "X-Title")
        request.httpBody = httpBody
        
        let (bytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenRouterError.invalidResponse
        }
        
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            
            while let newlineRange = buffer.range(of: Data([UInt8(ascii: "\n")])) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer = Data(buffer[newlineRange.upperBound...])
                
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data: ") else { continue }
                
                let jsonStr = String(trimmedLine.dropFirst(6))
                guard jsonStr != "[DONE]" else { return }
                
                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    onChunk(content)
                }
            }
        }
    }
}