import Foundation

@Observable
final class AgentHarness {
    var messages: [Message] = []
    var status: AgentStatus = .idle
    var currentModel: String = DefaultModels.preferred
    
    private let client = OpenRouterClient.shared
    private var systemPrompt: String
    private var task: Task<Void, Never>?
    
    init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        resetConversation()
    }
    
    static let defaultSystemPrompt = """
    You are a helpful AI assistant integrated into a macOS menu bar app called John.
    You help users with coding, writing, analysis, and general tasks.
    
    Be concise and helpful. Format code blocks with appropriate language tags.
    If you need clarification, ask brief questions.
    """
    
    var apiKey: String {
        KeychainManager.retrieveOrEmpty(key: "openrouter_api_key")
    }
    
    var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    func send(_ userInput: String) async {
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
                let response = try await self.client.chatCompletion(
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
    
    func sendStreaming(_ userInput: String) async {
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
                try await self.client.streamCompletion(
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
    }
    
    func updateSystemPrompt(_ newPrompt: String) {
        self.systemPrompt = newPrompt
        resetConversation()
    }
    
    func setModel(_ model: String) {
        self.currentModel = model
    }
}