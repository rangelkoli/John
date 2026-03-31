import SwiftUI

struct PanelContentView: View {
    @Bindable var harness: AgentHarness
    let onClose: () -> Void

    @State private var inputText = ""
    @State private var isScrolling = false
    @FocusState private var isInputFocused: Bool
    @State private var musicService = MusicPlayerService()
    
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            
            ChatView(harness: harness, inputText: $inputText, isInputFocused: _isInputFocused)
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
