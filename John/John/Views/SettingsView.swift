import SwiftUI

struct SettingsView: View {
    @Bindable var harness: AgentHarness
    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var customSystemPrompt: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            // API Configuration Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Configuration")
                    .font(.headline)
                
                HStack {
                    if showAPIKey {
                        TextField("OpenRouter API Key", text: $apiKey)
                    } else {
                        SecureField("OpenRouter API Key", text: $apiKey)
                    }
                    
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
                
                HStack {
                    Button("Save API Key") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.isEmpty)
                    
                    Link("Get API Key", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                }
            }
            
            Divider()
            
            // Model Selection Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Model Selection")
                    .font(.headline)
                
                Picker("Model", selection: $harness.currentModel) {
                    ForEach(DefaultModels.available, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Divider()
            
            // System Prompt Section
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .font(.headline)
                
                TextEditor(text: $customSystemPrompt)
                    .frame(height: 80)
                    .font(.system(size: 11, design: .monospaced))
                    .border(Color.gray.opacity(0.3))
                
                HStack {
                    Button("Apply") {
                        harness.updateSystemPrompt(customSystemPrompt)
                    }
                    .disabled(customSystemPrompt.isEmpty)
                    
                    Button("Reset to Default") {
                        customSystemPrompt = AgentHarness.defaultSystemPrompt
                    }
                }
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Clear Conversation") {
                    harness.resetConversation()
                }
                
                Spacer()
                
                Button("Done") {
                    NSApplication.shared.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400, height: 480)
        .onAppear {
            loadAPIKey()
            customSystemPrompt = AgentHarness.defaultSystemPrompt
        }
    }
    
    private func saveAPIKey() {
        do {
            try KeychainManager.save(key: "openrouter_api_key", value: apiKey)
        } catch {
            print("Failed to save API key: \(error)")
        }
    }
    
    private func loadAPIKey() {
        apiKey = KeychainManager.retrieveOrEmpty(key: "openrouter_api_key")
    }
}