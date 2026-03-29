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
    }
    
    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(harness.messages.filter { $0.role != .system }) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    
                    if case .thinking(let tool) = harness.status {
                        thinkingIndicator(tool)
                    }
                }
                .padding()
            }
            .onChange(of: harness.messages.count) {
                withAnimation {
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
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            if let tool {
                Text(tool)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Thinking...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .lineLimit(1...6)
                .onSubmit {
                    sendMessage()
                }
                .disabled(!harness.isConfigured || harness.status.isActive)
            
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(sendButtonColor)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || !harness.isConfigured || harness.status.isActive)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var sendButtonColor: Color {
        if !harness.isConfigured {
            return .gray
        }
        if inputText.isEmpty {
            return .gray
        }
        if harness.status.isActive {
            return .gray
        }
        return .accentColor
    }
    
    private var apiKeyWarning: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Configure your OpenRouter API key in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Settings") {
                NotificationCenter.default.post(name: .ShowSettings, object: nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
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