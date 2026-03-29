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
            
            Divider()
            
            ChatView(harness: harness, inputText: $inputText, isInputFocused: _isInputFocused)
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var titleBar: some View {
        HStack {
            Text("John")
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
            
            HStack(spacing: 12) {
                modelPicker
                settingsButton
                closeButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
    
    private var modelPicker: some View {
        Menu {
            ForEach(DefaultModels.available, id: \.id) { model in
                Button(model.name) {
                    harness.setModel(model.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shortModelName(harness.currentModel))
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
    }
    
    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .ShowSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
    
    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
    
    private func shortModelName(_ id: String) -> String {
        DefaultModels.available.first { $0.id == id }?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }
}