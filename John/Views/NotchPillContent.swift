import SwiftUI

struct NotchPillContent: View {
    var isHovering: Bool = false
    var harness: AgentHarness?
    
    private var displayStatus: AgentStatus {
        harness?.status ?? .idle
    }
    
    var body: some View {
        ZStack {
            HStack {
                if displayStatus != .idle {
                    Rectangle()
                        .foregroundColor(.clear)
                        .frame(width: 18, height: 18)
                        .overlay(alignment: .leading) {
                            BotFaceView()
                                .frame(width: 20, height: 15)
                                .mask(RoundedRectangle(cornerRadius: 5))
                        }
                    
                    Spacer()
                    
                    switch displayStatus {
                    case .taskCompleted:
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity
                            ))
                    case .waitingForInput:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.yellow)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity
                            ))
                    case .thinking:
                        SpinnerView()
                            .frame(width: 14, height: 14)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity
                            ))
                    case .idle:
                        EmptyView()
                    case .error:
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.red)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
            }
            .animation(
                .timingCurve(0.23, 1, 0.32, 1, duration: 0.35),
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
}

struct SpinnerView: View {
    @State private var isAnimating = false
    
    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

struct BotFaceView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
            Circle()
                .fill(Color.black)
                .frame(width: 4, height: 4)
        }
    }
}