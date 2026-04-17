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
    var voiceService: VoiceService?

    private let backendClient = BackendClient.shared
    private let openRouterClient = OpenRouterClient.shared
    private var systemPrompt: String
    private var task: Task<Void, Never>?
    private var threadId: String = "default"

    init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        resetConversation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let vs = VoiceService()
            vs.harness = self
            self.voiceService = vs
            await self.checkBackendHealth()
            vs.restoreEnabledState()
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
    
    func sendStreamingAndWait(_ userInput: String) async -> String {
        guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        
        let assistantIndex = await MainActor.run {
            let userMessage = Message(role: .user, content: userInput)
            messages.append(userMessage)
            status = .thinking(nil)
            let assistantMessage = Message(role: .assistant, content: "")
            messages.append(assistantMessage)
            return messages.count - 1
        }
        
        if backend == .langchainBackend && isBackendHealthy {
            return await sendStreamingViaBackendAndWait(userInput, assistantIndex: assistantIndex)
        } else {
            return await sendStreamingViaOpenRouterAndWait(userInput, assistantIndex: assistantIndex)
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
        
        await MainActor.run {
            let userMessage = Message(role: .user, content: userInput)
            messages.append(userMessage)
            status = .thinking(nil)
        }
        
        var accumulatedContent = ""
        let assistantIndex = await MainActor.run {
            let assistantMessage = Message(role: .assistant, content: "")
            messages.append(assistantMessage)
            return messages.count - 1
        }

        print("[DEBUG] Backend streaming started, assistantIndex=\(assistantIndex)")
        
        task = Task { [weak self] in
            guard let self else { return }
            
            do {
                try await self.backendClient.streamChat(
                    message: userInput,
                    threadId: self.threadId
                ) { event in
                    if let type = event.type, type == "token", let accumulated = event.accumulated {
                        accumulatedContent = accumulated
                    } else if let output = event.output {
                        if let response = output.final_response ?? output.response {
                            accumulatedContent = response
                        } else if let msgs = output.messages {
                            for msg in msgs {
                                if let content = msg.content, let type = msg.type, type == "ai" {
                                    accumulatedContent = content
                                }
                            }
                        }
                    }
                    
                    print("[DEBUG] Backend chunk received, type=\(event.type ?? "unknown"), accumulatedContent length=\(accumulatedContent.count)")
                    
                    DispatchQueue.main.async {
                        var updated = self.messages
                        updated[assistantIndex] = Message(
                            id: self.messages[assistantIndex].id,
                            role: .assistant,
                            content: accumulatedContent,
                            timestamp: self.messages[assistantIndex].timestamp
                        )
                        self.messages = updated
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
                        print("[DEBUG] Backend streaming error: \(error.localizedDescription)")
                        if accumulatedContent.isEmpty {
                            self.messages.removeLast()
                        }
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
        
        await MainActor.run {
            let userMessage = Message(role: .user, content: userInput)
            messages.append(userMessage)
            status = .thinking(nil)
        }
        
        var accumulatedContent = ""
        let assistantIndex = await MainActor.run {
            let assistantMessage = Message(role: .assistant, content: "")
            messages.append(assistantMessage)
            return messages.count - 1
        }

        print("[DEBUG] Assistant message appended at index \(assistantIndex)")
        
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
                        var updated = self.messages
                        updated[assistantIndex] = Message(
                            id: self.messages[assistantIndex].id,
                            role: .assistant,
                            content: accumulatedContent,
                            timestamp: self.messages[assistantIndex].timestamp
                        )
                        self.messages = updated
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
                        print("[DEBUG] Error: \(error.localizedDescription)")
                        if accumulatedContent.isEmpty {
                            self.messages.removeLast()
                        }
                        self.status = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func sendStreamingViaBackendAndWait(_ userInput: String, assistantIndex: Int) async -> String {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return ""
        }
        
        var accumulatedContent = ""
        
        print("[DEBUG] Backend streaming started (wait), assistantIndex=\(assistantIndex)")
        
        do {
            try await self.backendClient.streamChat(
                message: userInput,
                threadId: self.threadId
            ) { event in
                if let type = event.type, type == "token", let accumulated = event.accumulated {
                    accumulatedContent = accumulated
                } else if let output = event.output {
                    if let response = output.final_response ?? output.response {
                        accumulatedContent = response
                    } else if let msgs = output.messages {
                        for msg in msgs {
                            if let content = msg.content, let type = msg.type, type == "ai" {
                                accumulatedContent = content
                            }
                        }
                    }
                }
                
                print("[DEBUG] Backend chunk (wait), accumulatedContent length=\(accumulatedContent.count)")
                
                DispatchQueue.main.async {
                    var updated = self.messages
                    updated[assistantIndex] = Message(
                        id: self.messages[assistantIndex].id,
                        role: .assistant,
                        content: accumulatedContent,
                        timestamp: self.messages[assistantIndex].timestamp
                    )
                    self.messages = updated
                }
            }
            
            await MainActor.run {
                self.status = .idle
            }
        } catch {
            await MainActor.run {
                print("[DEBUG] Backend streaming error (wait): \(error.localizedDescription)")
                self.messages.removeLast()
                self.status = .error(error.localizedDescription)
            }
        }
        
        return accumulatedContent
    }
    
    private func sendStreamingViaOpenRouterAndWait(_ userInput: String, assistantIndex: Int) async -> String {
        guard isConfigured else {
            status = .error("Please configure your OpenRouter API key in Settings")
            return ""
        }
        
        var accumulatedContent = ""
        
        print("[DEBUG] OpenRouter streaming started (wait), assistantIndex=\(assistantIndex)")
        
        do {
            try await self.openRouterClient.streamCompletion(
                messages: self.messages.dropLast(),
                model: self.currentModel,
                apiKey: self.apiKey
            ) { chunk in
                accumulatedContent += chunk
                Task { @MainActor in
                    var updated = self.messages
                    updated[assistantIndex] = Message(
                        id: self.messages[assistantIndex].id,
                        role: .assistant,
                        content: accumulatedContent,
                        timestamp: self.messages[assistantIndex].timestamp
                    )
                    self.messages = updated
                }
            }
            
            await MainActor.run {
                self.status = .idle
            }
        } catch {
            await MainActor.run {
                print("[DEBUG] OpenRouter streaming error (wait): \(error.localizedDescription)")
                self.messages.removeLast()
                self.status = .error(error.localizedDescription)
            }
        }
        
        return accumulatedContent
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