import SwiftUI

struct ChatView: View {
    @Bindable var harness: AgentHarness
    @Binding var inputText: String
    @FocusState var isInputFocused: Bool

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        inputBar
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .onReceive(NotificationCenter.default.publisher(for: .FocusInput)) { _ in
                isInputFocused = true
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
                    .background(Circle().fill(sendButtonBackground))
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || !harness.isConfigured || harness.status.isActive)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: inputText.isEmpty)
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
            do {
                try await harness.sendStreaming(text)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
