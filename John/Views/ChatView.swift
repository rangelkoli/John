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
    
    private func thinkingIndicator(_ tool: String?) -> some View {
        let title = tool ?? "Thinking..."
        
        return HStack(spacing: 14) {
            thinkingAvatar
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text("Processing your request")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(thinkingBackground)
        .padding(.horizontal, 60)
    }
    
    private var thinkingAvatar: some View {
        ZStack {
            Circle()
                .fill(thinkingGradient)
                .frame(width: 32, height: 32)
                .shadow(color: Color.purple.opacity(0.3), radius: 4, x: 0, y: 2)
            
            ProgressView()
                .scaleEffect(0.65)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }
    
    private var thinkingGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.545, green: 0.361, blue: 0.965),
                Color(red: 0.388, green: 0.4, blue: 0.945),
                Color(red: 0.231, green: 0.510, blue: 0.965)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var thinkingBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
    
    private var inputBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "message.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
                
                TextField("Ask me anything...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .onSubmit {
                        sendMessage()
                    }
                    .disabled(!harness.isConfigured || harness.status.isActive)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(inputFieldBackground)
            
            Button {
                sendMessage()
            } label: {
                ZStack {
                    Circle()
                        .fill(sendButtonGradient)
                        .frame(width: 40, height: 40)
                        .shadow(
                            color: sendButtonShadow,
                            radius: 6,
                            x: 0,
                            y: 3
                        )
                    
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(sendButtonForeground)
                        .offset(y: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || !harness.isConfigured || harness.status.isActive)
            .scaleEffect(inputText.isEmpty ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: -1)
        )
    }
    
    private var inputFieldBackground: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(inputBorderColor, lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
    
    private var inputBorderColor: LinearGradient {
        LinearGradient(
            colors: isInputFocused 
                ? [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0.3)]
                : [Color.gray.opacity(0.15), Color.gray.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var sendButtonGradient: LinearGradient {
        if !harness.isConfigured || inputText.isEmpty || harness.status.isActive {
            return LinearGradient(
                colors: [Color.gray.opacity(0.25), Color.gray.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.accentColor.opacity(1.0), Color.accentColor.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var sendButtonShadow: Color {
        if !harness.isConfigured || inputText.isEmpty || harness.status.isActive {
            return Color.gray.opacity(0.2)
        }
        return Color.accentColor.opacity(0.4)
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