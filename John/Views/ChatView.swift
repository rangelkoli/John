import SwiftUI

struct ChatView: View {
    @Bindable var harness: AgentHarness
    @Binding var inputText: String
    @FocusState var isInputFocused: Bool
    
    @State private var errorMessage: String?
    @State private var showingError = false
    
    var body: some View {
        VStack(spacing: 0) {
            messagesList
            
            Divider()
                .opacity(0.5)
            
            inputBar
            
            if !harness.isConfigured {
                apiKeyWarning
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
        .onReceive(NotificationCenter.default.publisher(for: .FocusInput)) { _ in
            isInputFocused = true
        }
    }
    
    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(harness.messages.filter { $0.role != .system }) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    
                    if case .thinking(let tool) = harness.status {
                        thinkingIndicator(tool)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: harness.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastMessage = harness.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: harness.status) {
                if case .idle = harness.status {
                    if let lastMessage = harness.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func thinkingIndicator(_ tool: String?) -> some View {
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
                    .frame(width: 28, height: 28)
                
                ProgressView()
                    .scaleEffect(0.6)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if let tool {
                    Text(tool)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                } else {
                    Text("Thinking...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                Text("Processing your request")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
        .padding(.horizontal, 40)
    }
    
    private var inputBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "message.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
                
                TextField("Ask me anything...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .font(.system(size: 14))
                    .onSubmit {
                        sendMessage()
                    }
                    .disabled(!harness.isConfigured || harness.status.isActive)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
            
            Button {
                sendMessage()
            } label: {
                ZStack {
                    Circle()
                        .fill(sendButtonBackground)
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(sendButtonForeground)
                }
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || !harness.isConfigured || harness.status.isActive)
            .scaleEffect(inputText.isEmpty ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var sendButtonBackground: Color {
        if !harness.isConfigured || inputText.isEmpty || harness.status.isActive {
            return Color.gray.opacity(0.2)
        }
        return Color.accentColor
    }
    
    private var sendButtonForeground: Color {
        if !harness.isConfigured || inputText.isEmpty || harness.status.isActive {
            return Color.gray.opacity(0.5)
        }
        return .white
    }
    
    private var apiKeyWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
            
            Text("Configure your OpenRouter API key in Settings")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            
            Spacer()
            
            Button("Settings") {
                NotificationCenter.default.post(name: .ShowSettings, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard harness.isConfigured else { return }
        guard !harness.status.isActive else { return }
        
        inputText = ""
        Task {
            do {
                try await harness.sendStreaming(text)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
