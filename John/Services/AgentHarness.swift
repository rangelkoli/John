import Foundation

enum AgentBackend {
    case langchainBackend
    case openRouterDirect
}

@Observable
final class AgentHarness {
    var messages: [Message] = []
    var status: AgentStatus = .idle
    var currentModel: String = DefaultModels.preferred
    var backend: AgentBackend = .langchainBackend
    var isBackendHealthy: Bool = false
    
    private let backendClient = BackendClient.shared
    private let openRouterClient = OpenRouterClient.shared
    private var systemPrompt: String
    private var task: Task<Void, Never>?
    private var threadId: String = "default"
    
    init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        resetConversation()
        Task {
            await checkBackendHealth()
        }
    }
    
    static let defaultSystemPrompt = """
    You are a helpful AI assistant integrated into a macOS menu bar app called John.
    You help users with coding, writing, analysis, and general tasks.
    
    Be concise and helpful. Format code blocks with appropriate language tags.
    If you need clarification, ask brief questions.
    """
    
    var apiKey: String {
        if let envKey = EnvManager.loadAPIKey(), !envKey.isEmpty {
            return envKey
        }
        return KeychainManager.retrieveOrEmpty(key: "openrouter_api_key")
    }
    
    var apiKeySource: String {
        if EnvManager.loadAPIKey() != nil {
            return "Environment"
        }
        if !KeychainManager.retrieveOrEmpty(key: "openrouter_api_key").isEmpty {
            return "Keychain"
        }
        return "Not Set"
    }
    
    var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    func checkBackendHealth() async {
        do {
            _ = try await backendClient.checkHealth()
            await MainActor.run {
                isBackendHealthy = true
            }
        } catch {
            await MainActor.run {
                isBackendHealthy = false
            }
        }
    }
    
    func send(_ userInput: String) async {
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        if backend == .langchainBackend && isBackendHealthy {
            await sendViaBackend(userInput)
        } else {
            await sendViaOpenRouter(userInput)
        }
    }
    
    func sendStreaming(_ userInput: String) async {
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        if backend == .langchainBackend && isBackendHealthy {
            await sendStreamingViaBackend(userInput)
        } else {
            await sendStreamingViaOpenRouter(userInput)
        }
    }
    
    private func sendViaBackend(_ userInput: String) async {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return
        }
        
        let userMessage = Message(role: .user, content: userInput)
        messages.append(userMessage)
        status = .thinking(nil)
        
        task = Task { [weak self] in
            guard let self else { return }
            
            do {
                let response = try await self.backendClient.sendChat(
                    message: userInput,
                    threadId: self.threadId
                )
                
                if !Task.isCancelled {
                    let content = response.response ?? ""
                    let assistantMessage = Message(role: .assistant, content: content)
                    await MainActor.run {
                        self.messages.append(assistantMessage)
                        self.status = .idle
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.status = .error(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    private func sendStreamingViaBackend(_ userInput: String) async {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return
        }
        
        let userMessage = Message(role: .user, content: userInput)
        messages.append(userMessage)
        status = .thinking(nil)
        
        var accumulatedContent = ""
        let assistantMessage = Message(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1
        
        task = Task { [weak self] in
            guard let self else { return }
            
            do {
                try await self.backendClient.streamChat(
                    message: userInput,
                    threadId: self.threadId
                ) { event in
                    if let output = event.output {
                        if let messages = output.messages {
                            for msg in messages {
                                if let content = msg.content, let type = msg.type {
                                    if type == "ai" {
                                        accumulatedContent = content
                                    }
                                }
                            }
                        }
                        if let response = output.response {
                            accumulatedContent = response
                        }
                    }
                    
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.messages[assistantIndex] = Message(
                            id: self.messages[assistantIndex].id,
                            role: .assistant,
                            content: accumulatedContent,
                            timestamp: self.messages[assistantIndex].timestamp
                        )
                    }
                }
                
                if !Task.isCancelled {
                    await MainActor.run {
                        self.status = .idle
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.messages.removeLast()
                        self.status = .error(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    private func sendViaOpenRouter(_ userInput: String) async {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return
        }
        
        let userMessage = Message(role: .user, content: userInput)
        messages.append(userMessage)
        status = .thinking(nil)
        
        task = Task { [weak self] in
            guard let self else { return }
            
            do {
                let response = try await self.openRouterClient.chatCompletion(
                    messages: self.messages,
                    model: self.currentModel,
                    apiKey: self.apiKey
                )
                
                if !Task.isCancelled {
                    let assistantMessage = Message(role: .assistant, content: response)
                    self.messages.append(assistantMessage)
                    self.status = .idle
                }
            } catch {
                if !Task.isCancelled {
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }
    
    private func sendStreamingViaOpenRouter(_ userInput: String) async {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return
        }
        
        let userMessage = Message(role: .user, content: userInput)
        messages.append(userMessage)
        status = .thinking(nil)
        
        var accumulatedContent = ""
        let assistantMessage = Message(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1
        
        task = Task { [weak self] in
            guard let self else { return }
            
            do {
                try await self.openRouterClient.streamCompletion(
                    messages: self.messages.dropLast(),
                    model: self.currentModel,
                    apiKey: self.apiKey
                ) { chunk in
                    accumulatedContent += chunk
                    Task { @MainActor in
                        self.messages[assistantIndex] = Message(
                            id: self.messages[assistantIndex].id,
                            role: .assistant,
                            content: accumulatedContent,
                            timestamp: self.messages[assistantIndex].timestamp
                        )
                    }
                }
                
                if !Task.isCancelled {
                    self.status = .idle
                }
            } catch {
                if !Task.isCancelled {
                    self.messages.removeLast()
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }
    
    func cancel() {
        task?.cancel()
        task = nil
        status = .idle
    }
    
    func resetConversation() {
        messages = [Message(role: .system, content: systemPrompt)]
        status = .idle
        task?.cancel()
        task = nil
        threadId = UUID().uuidString
        
        Task {
            try? await backendClient.resetConversation(threadId: threadId)
        }
    }
    
    func updateSystemPrompt(_ newPrompt: String) {
        self.systemPrompt = newPrompt
        resetConversation()
    }
    
    func setModel(_ model: String) {
        self.currentModel = model
    }
    
    func setBackend(_ newBackend: AgentBackend) {
        self.backend = newBackend
        Task {
            await checkBackendHealth()
        }
    }
}