import SwiftUI

struct PanelContentView: View {
    @Bindable var harness: AgentHarness
    let onClose: () -> Void
    
    @State private var inputText = ""
    @State private var isScrolling = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            
            ChatView(harness: harness, inputText: $inputText, isInputFocused: _isInputFocused)
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 420, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
    
    private var titleBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("John")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Text("AI Assistant")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                modelPicker
                
                Divider()
                    .frame(height: 20)
                    .opacity(0.3)
                
                settingsButton
                closeButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.98)
        )
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .frame(height: 1)
                .offset(y: 0),
            alignment: .bottom
        )
    }
    
    private var modelPicker: some View {
        Menu {
            ForEach(DefaultModels.available, id: \.id) { model in
                Button(model.name) {
                    harness.setModel(model.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text(shortModelName(harness.currentModel))
                    .font(.system(size: 12, weight: .medium))
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
    }
    
    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .ShowSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.gray.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }
    
    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.gray.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }
    
    private func shortModelName(_ id: String) -> String {
        DefaultModels.available.first { $0.id == id }?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }
}
