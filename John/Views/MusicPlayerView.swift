import SwiftUI

struct MusicPlayerView: View {
    @Bindable var musicService: MusicPlayerService
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            albumArtSection
            trackInfoSection
            progressSection
            transportControls
            secondaryControls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumArtSection: some View {
        ZStack {
            if let art = musicService.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: isPlaying ? 16 : 8, x: 0, y: isPlaying ? 8 : 4)
        .scaleEffect(isPlaying ? 1.0 : 0.95)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isPlaying)
    }

    private var trackInfoSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(musicService.trackName.isEmpty ? "Nothing Playing" : musicService.trackName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if musicService.isPlaying {
                    MusicVisualizerView(isPlaying: musicService.isPlaying)
                        .frame(width: 16, height: 14)
                }
            }
            if !musicService.artistName.isEmpty {
                Text(musicService.artistName)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: geo.size.width * (isDraggingProgress ? dragProgress : musicService.progress), height: 4)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingProgress = true
                        dragProgress = max(0, min(value.location.x / geo.size.width, 1.0))
                    }
                    .onEnded { value in
                        let p = max(0, min(value.location.x / geo.size.width, 1.0))
                        musicService.seek(to: p)
                        isDraggingProgress = false
                    }
                )
            }
            .frame(height: 4)

            HStack {
                Text(musicService.elapsedTime.formattedDuration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(musicService.duration.formattedDuration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button(action: { musicService.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            Button(action: { musicService.togglePlayPause() }) {
                ZStack {
                    Circle().fill(Color.white).frame(width: 52, height: 52)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.black)
                }
            }
            .buttonStyle(.plain)

            Button(action: { musicService.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 24) {
            Button(action: { musicService.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14))
                    .foregroundColor(musicService.shuffleMode ? .white : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { musicService.toggleRepeat() }) {
                Image(systemName: musicService.repeatMode.systemImage)
                    .font(.system(size: 14))
                    .foregroundColor(musicService.repeatMode != .off ? .white : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    private var isPlaying: Bool { musicService.isPlaying }
}
