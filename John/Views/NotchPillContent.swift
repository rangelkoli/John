import SwiftUI

struct NotchPillContent: View {
    var isHovering: Bool = false
    var harness: AgentHarness?
    var isPanelOpen: Bool = false
    
    private var displayStatus: AgentStatus {
        harness?.status ?? .idle
    }
    
    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if displayStatus != .idle {
                    // Bot Face with enhanced styling
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.95),
                                        Color.white.opacity(0.8)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 22, height: 22)
                            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                        
                        BotFaceView()
                            .frame(width: 14, height: 10)
                    }
                    
                    Spacer()
                    
                    // Status indicator with enhanced animations
                    statusIndicator
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal: .scale(scale: 0.5).combined(with: .opacity)
                        ))
                }
            }
            .animation(
                .spring(response: 0.35, dampingFraction: 0.75),
                value: displayStatus
            )
            .padding(.horizontal, 12 + (isHovering ? NotchPillView.earRadius : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .offset(y: isHovering ? -3 : -2)
        .onChange(of: displayStatus) {
            NotificationCenter.default.post(name: .JohnStatusChanged, object: nil)
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch displayStatus {
        case .taskCompleted:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 22, height: 22)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green)
            }
            
        case .waitingForInput:
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.2))
                    .frame(width: 22, height: 22)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.yellow)
            }
            
        case .thinking:
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 22, height: 22)
                
                SpinnerView()
                    .frame(width: 12, height: 12)
            }
            
        case .idle:
            EmptyView()
            
        case .error:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 22, height: 22)
                
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
            }
        }
    }
}

struct SpinnerView: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                .frame(width: 14, height: 14)
            
            // Spinning arc
            Circle()
                .trim(from: 0.1, to: 0.7)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white, Color.white.opacity(0.7)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(
                    .linear(duration: 0.9)
                    .repeatForever(autoreverses: false),
                    value: isAnimating
                )
        }
        .onAppear { isAnimating = true }
    }
}

struct BotFaceView: View {
    @State private var isBlinking = false
    @State private var blinkScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Eye background
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black)
                .frame(width: 12, height: 8)
            
            // Animated eye
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white, Color.white.opacity(0.9)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isBlinking ? 12 : 6, height: isBlinking ? 2 : 6)
                .scaleEffect(blinkScale)
                .animation(.easeInOut(duration: 0.15), value: isBlinking)
                .onAppear {
                    startBlinking()
                }
        }
    }
    
    private func startBlinking() {
        // Random blinking interval
        let delay = Double.random(in: 2.0...5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isBlinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isBlinking = false
                startBlinking()
            }
        }
    }
}
