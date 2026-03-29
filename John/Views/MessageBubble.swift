import SwiftUI

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == .assistant {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant {
                    assistantHeader
                }
                
                Text(message.content)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundColor(message.role == .user ? .white : .primary)
            }
            .padding(12)
            .background(bubbleBackground)
            .cornerRadius(16)
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .user {
                Spacer(minLength: 40)
            }
        }
    }
    
    @ViewBuilder
    private var assistantHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Assistant")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return Color.accentColor
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }
}