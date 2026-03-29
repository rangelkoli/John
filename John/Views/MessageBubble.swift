import SwiftUI

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Spacer(minLength: 40)
            } else {
                userAvatar
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    assistantHeader
                }
                
                if message.role == .assistant {
                    // Render markdown for assistant messages
                    MarkdownText(content: message.content)
                        .textSelection(.enabled)
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .lineSpacing(3)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 2)
                } else {
                    // Plain text for user messages
                    Text(message.content)
                        .textSelection(.enabled)
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .lineSpacing(3)
                        .foregroundColor(.white)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(bubbleBackground)
            .cornerRadius(18, corners: message.role == .user ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight])
            .frame(maxWidth: 520, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .assistant {
                assistantAvatar
            } else {
                Spacer(minLength: 40)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var userAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 28, height: 28)
            Image(systemName: "person.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
        }
    }
    
    private var assistantAvatar: some View {
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
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
    }
    
    @ViewBuilder
    private var assistantHeader: some View {
        HStack(spacing: 6) {
            Text("John")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            
            Spacer()
            
            Text(message.timestamp, style: .time)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.bottom, 4)
    }
    
    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return Color.accentColor
        } else {
            return Color(nsColor: .controlBackgroundColor).opacity(0.8)
        }
    }
}

// MARK: - Corner Radius Helper

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let topLeft: CGFloat = corners.contains(.topLeft) ? radius : 0
        let topRight: CGFloat = corners.contains(.topRight) ? radius : 0
        let bottomLeft: CGFloat = corners.contains(.bottomLeft) ? radius : 0
        let bottomRight: CGFloat = corners.contains(.bottomRight) ? radius : 0
        
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        if topRight > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight), radius: topRight, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        if topLeft > 0 {
            path.addArc(center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft), radius: topLeft, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        
        return path
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

#if canImport(UIKit)
import UIKit
typealias UIRectCorner = UIKit.UIRectCorner
#else
struct UIRectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = UIRectCorner(rawValue: 1 << 0)
    static let topRight = UIRectCorner(rawValue: 1 << 1)
    static let bottomLeft = UIRectCorner(rawValue: 1 << 2)
    static let bottomRight = UIRectCorner(rawValue: 1 << 3)
    static let allCorners: UIRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
#endif

// MARK: - Markdown Text View

struct MarkdownText: View {
    let content: String
    
    var body: some View {
        if let attributedString = try? AttributedString(markdown: content, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributedString)
        } else if let attributedString = try? AttributedString(markdown: content) {
            Text(attributedString)
        } else {
            Text(content)
        }
    }
}
