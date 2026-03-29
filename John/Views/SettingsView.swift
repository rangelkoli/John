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
                
                // Show current source
                HStack {
                    Text("Source:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(harness.apiKeySource)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(harness.apiKeySource == "Not Set" ? .red : .green)
                    
                    if harness.apiKeySource == "Environment" {
                        if let foundPath = EnvManager.getFoundEnvPath() {
                            Text("(\(foundPath))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                
                // Env file instructions
                VStack(alignment: .leading, spacing: 4) {
                    Text("To use environment file, create:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("~/.john.env")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("with: OPENROUTER_API_KEY=your_key_here")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                
                // Manual override
                Text("Or save manually below (override):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
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
                    Button("Save to Keychain") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.isEmpty)
                    
                    if !KeychainManager.retrieveOrEmpty(key: "openrouter_api_key").isEmpty {
                        Button("Clear Keychain") {
                            try? KeychainManager.delete(key: "openrouter_api_key")
                            apiKey = ""
                        }
                        .foregroundColor(.red)
                    }
                    
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
        .frame(width: 420, height: 520)
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
        // Show keychain value if set, otherwise show env value if available
        let keychainKey = KeychainManager.retrieveOrEmpty(key: "openrouter_api_key")
        if !keychainKey.isEmpty {
            apiKey = keychainKey
        } else if let envKey = EnvManager.loadAPIKey() {
            // Show placeholder for env key
            apiKey = String(envKey.prefix(8)) + "..." + String(envKey.suffix(4))
        }
    }
}