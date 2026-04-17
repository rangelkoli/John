import SwiftUI

struct ChatView: View {
    @Bindable var harness: AgentHarness
    @Binding var inputText: String
    @FocusState var isInputFocused: Bool
    var onHeightChange: (CGFloat) -> Void

    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var lastReportedHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if harness.status.isActive || !currentResponse.isEmpty || harness.status.isError {
                responseArea
            } else if let vs = harness.voiceService, vs.voiceState == .activated, !vs.activatedTranscript.isEmpty {
                voiceTranscriptArea
            } else {
                Spacer()
            }
            inputBar
        }
        .frame(maxHeight: .infinity)
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
        .onReceive(NotificationCenter.default.publisher(for: .FocusInput)) { _ in
            isInputFocused = true
        }
    }

    private var currentResponse: String {
        harness.messages.last(where: { $0.role == .assistant })?.content ?? ""
    }

    private var latestAssistantMessage: Message? {
        harness.messages.last(where: { $0.role == .assistant })
    }

    private var voiceTranscriptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .opacity(0.8)
                    .scaleEffect(isVoiceActive ? 1.2 : 1.0)
                    .overlay(
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 2)
                            .scaleEffect(1.5)
                    )
                
                Text("Listening...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            if let vs = harness.voiceService, !vs.activatedTranscript.isEmpty {
                Text(vs.activatedTranscript)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .lineSpacing(4)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var isVoiceActive: Bool {
        harness.voiceService?.voiceState == .activated
    }
    
    private var responseArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = latestAssistantMessage {
                        MessageContentView(content: message.content)
                            .textSelection(.enabled)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .lineSpacing(4)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 4)
                            .id(message.id)
                    }
                    if harness.status.isActive {
                        LoadingIndicator()
                            .id("loading")
                    }
                    if let errorMsg = harness.status.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            Text(errorMsg)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ResponseHeightPreference.self,
                            value: geometry.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(ResponseHeightPreference.self) { height in
                guard abs(height - lastReportedHeight) > 15 else { return }
                lastReportedHeight = height
                onHeightChange(height + 70)
            }
            .onChange(of: harness.messages) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if harness.status.isActive {
                        proxy.scrollTo("loading", anchor: .bottom)
                    } else if let message = latestAssistantMessage {
                        proxy.scrollTo(message.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask me anything...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .lineLimit(1...4)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .onSubmit { sendMessage() }
                .disabled(!harness.isConfigured || harness.status.isActive)

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(sendButtonForeground)
                    .frame(width: 28, height: 28)
                    .scaleEffect(isSendButtonEnabled ? 1.0 : 0.85)
                    .background(Circle().fill(sendButtonBackground))
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || !harness.isConfigured || harness.status.isActive)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: inputText.isEmpty)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSendButtonEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            isInputFocused ? Color.accentColor.opacity(0.45) : Color.gray.opacity(0.18),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private var isSendButtonEnabled: Bool {
        !inputText.isEmpty && harness.isConfigured && !harness.status.isActive
    }

    private var sendButtonBackground: Color {
        inputText.isEmpty || !harness.isConfigured || harness.status.isActive
            ? Color.gray.opacity(0.15)
            : Color.accentColor
    }

    private var sendButtonForeground: Color {
        inputText.isEmpty || !harness.isConfigured || harness.status.isActive
            ? Color.gray.opacity(0.4)
            : .white
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, harness.isConfigured, !harness.status.isActive else { return }
        inputText = ""
        Task {
            await harness.sendStreaming(text)
        }
    }
}

struct ResponseHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MessageContentView: View {
    let content: String
    @State private var isAppearing = false
    
    var body: some View {
        MarkdownText(content: content)
            .opacity(isAppearing ? 1 : 0)
            .offset(y: isAppearing ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    isAppearing = true
                }
            }
    }
}

struct LoadingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            isAnimating = true
        }
    }
}
