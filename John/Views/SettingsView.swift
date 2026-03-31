import SwiftUI

struct SettingsView: View {
    @Bindable var harness: AgentHarness
    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var customSystemPrompt: String = ""
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.system(size: 22, weight: .bold))
                        
                        Text("Configure your AI assistant")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                
                // API Configuration Section
                settingsSection(icon: "key.fill", iconColor: .orange, title: "API Configuration") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Status Card
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(statusColor.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                
                                Image(systemName: statusIcon)
                                    .font(.system(size: 16))
                                    .foregroundColor(statusColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API Key Status")
                                    .font(.system(size: 13, weight: .semibold))
                                
                                HStack(spacing: 6) {
                                    Text(harness.apiKeySource)
                                        .font(.system(size: 12))
                                        .foregroundColor(statusColor)
                                    
                                    if harness.apiKeySource == "Environment", let foundPath = EnvManager.getFoundEnvPath() {
                                        Text("•")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        Text(foundPath)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(statusColor.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(statusColor.opacity(0.15), lineWidth: 1)
                                )
                        )
                        
                        // Instructions
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Setup Instructions")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                instructionRow(number: "1", text: "Create file at ~/.john.env")
                                instructionRow(number: "2", text: "Add: OPENROUTER_API_KEY=your_key_here")
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.06))
                        )
                        
                        // Manual Input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Or enter API key manually")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    
                                    Group {
                                        if showAPIKey {
                                            TextField("sk-or-...", text: $apiKey)
                                        } else {
                                            SecureField("Enter API key", text: $apiKey)
                                        }
                                    }
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                        )
                                )
                                
                                Button {
                                    showAPIKey.toggle()
                                } label: {
                                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            
                            HStack(spacing: 10) {
                                Button("Save to Keychain") {
                                    saveAPIKey()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(apiKey.isEmpty)
                                
                                if !KeychainManager.retrieveOrEmpty(key: "openrouter_api_key").isEmpty {
                                    Button("Clear") {
                                        try? KeychainManager.delete(key: "openrouter_api_key")
                                        apiKey = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)
                                }
                                
                                Spacer()
                                
                                Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                                    HStack(spacing: 4) {
                                        Text("Get API Key")
                                            .font(.system(size: 12, weight: .medium))
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
                
                // System Prompt Section
                settingsSection(icon: "text.bubble", iconColor: .green, title: "System Prompt") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Customize how the AI behaves")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $customSystemPrompt)
                            .frame(height: 100)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .textBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                            )
                        
                        HStack(spacing: 10) {
                            Button("Apply Changes") {
                                harness.updateSystemPrompt(customSystemPrompt)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(customSystemPrompt.isEmpty)
                            
                            Button("Reset to Default") {
                                customSystemPrompt = AgentHarness.defaultSystemPrompt
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                
                // Actions Section
                settingsSection(icon: "gear", iconColor: .gray, title: "Actions") {
                    HStack(spacing: 12) {
                        Button {
                            harness.resetConversation()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                Text("Clear Conversation")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Spacer()
                        
                        Button("Done") {
                            NSApplication.shared.keyWindow?.close()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 460, height: 580)
        .onAppear {
            loadAPIKey()
            customSystemPrompt = AgentHarness.defaultSystemPrompt
        }
    }
    
    private func settingsSection<Content: View>(icon: String, iconColor: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                    
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            // Section Content
            content()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            
            Divider()
                .padding(.leading, 20)
        }
    }
    
    private func instructionRow(number: String, text: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 20, height: 20)
                
                Text(number)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
            }
            
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
    
    private var statusColor: Color {
        switch harness.apiKeySource {
        case "Not Set":
            return .red
        case "Environment":
            return .green
        case "Keychain":
            return .blue
        default:
            return .gray
        }
    }
    
    private var statusIcon: String {
        switch harness.apiKeySource {
        case "Not Set":
            return "exclamationmark.triangle.fill"
        case "Environment", "Keychain":
            return "checkmark.seal.fill"
        default:
            return "questionmark.circle"
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
        let keychainKey = KeychainManager.retrieveOrEmpty(key: "openrouter_api_key")
        if !keychainKey.isEmpty {
            apiKey = keychainKey
        } else if let envKey = EnvManager.loadAPIKey() {
            apiKey = String(envKey.prefix(8)) + "..." + String(envKey.suffix(4))
        }
    }
}
