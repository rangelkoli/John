import SwiftUI

struct PanelContentView: View {
    @Bindable var harness: AgentHarness
    let onClose: () -> Void

    @State private var inputText = ""
    @State private var isScrolling = false
    @FocusState private var isInputFocused: Bool
    @State private var musicService = MusicPlayerService()
    @State private var contentHeight: CGFloat = 0

    private let minContentHeight: CGFloat = 50
    private let titleBarHeight: CGFloat = 60
    private let minPanelHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            ChatView(harness: harness, inputText: $inputText, isInputFocused: _isInputFocused, onHeightChange: onHeightChange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .onAppear {
            resizePanel(height: minPanelHeight)
        }
    }

    private func onHeightChange(_ height: CGFloat) {
        let newHeight = max(minPanelHeight, height + titleBarHeight)
        resizePanel(height: newHeight)
    }

    private func resizePanel(height: CGFloat) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is AgentPanel }) else { return }
        guard let panel = window as? AgentPanel else { return }
        let clampedHeight = min(max(height, minPanelHeight), 800)
        let currentFrame = panel.frame
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - clampedHeight,
            width: currentFrame.width,
            height: clampedHeight
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
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
                if musicService.hasNowPlaying {
                    miniMusicPlayer

                    Divider()
                        .frame(height: 20)
                        .opacity(0.3)
                }

                voiceStatusButton

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
    
    private var miniMusicPlayer: some View {
        HStack(spacing: 6) {
            if let art = musicService.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(musicService.trackName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)

            HStack(spacing: 2) {
                Button { musicService.previousTrack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Button { musicService.togglePlayPause() } label: {
                    Image(systemName: musicService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.gray.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button { musicService.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
        )
    }

    @ViewBuilder
    private var voiceStatusButton: some View {
        let vs = harness.voiceService
        Button {
            if vs?.isEnabled == true {
                vs?.disable()
            } else {
                vs?.enable()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(voiceButtonBackground)
                    .frame(width: 28, height: 28)

                Image(systemName: voiceButtonIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(voiceButtonColor)
            }
        }
        .buttonStyle(.plain)
        .help(voiceButtonTooltip)
    }

    private var voiceButtonIcon: String {
        let state = harness.voiceService?.voiceState ?? .idle
        switch state {
        case .idle:
            return harness.voiceService?.isEnabled == true ? "waveform" : "waveform.slash"
        case .activated:
            return "waveform"
        case .processing:
            return "ellipsis"
        case .speaking:
            return "speaker.wave.2.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .permissionDenied:
            return "mic.slash.fill"
        }
    }

    private var voiceButtonColor: Color {
        let state = harness.voiceService?.voiceState ?? .idle
        switch state {
        case .idle:
            return harness.voiceService?.isEnabled == true ? .secondary : .secondary.opacity(0.5)
        case .activated:
            return .red
        case .processing:
            return .orange
        case .speaking:
            return .blue
        case .error:
            return .yellow
        case .permissionDenied:
            return .red
        }
    }

    private var voiceButtonBackground: Color {
        let state = harness.voiceService?.voiceState ?? .idle
        switch state {
        case .activated:
            return Color.red.opacity(0.15)
        case .processing:
            return Color.orange.opacity(0.12)
        case .speaking:
            return Color.blue.opacity(0.12)
        default:
            return Color.gray.opacity(0.1)
        }
    }

    private var voiceButtonTooltip: String {
        let state = harness.voiceService?.voiceState ?? .idle
        switch state {
        case .idle:
            return harness.voiceService?.isEnabled == true ? "Listening for 'Hey John' — click to disable" : "Voice disabled — click to enable"
        case .activated:
            let t = harness.voiceService?.activatedTranscript ?? ""
            return t.isEmpty ? "Listening..." : t
        case .processing:
            return "Processing your request..."
        case .speaking:
            return "Speaking response..."
        case .error(let msg):
            return "Voice error: \(msg)"
        case .permissionDenied:
            return "Microphone or speech recognition permission denied"
        }
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
    
}
