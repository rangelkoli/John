import SwiftUI

struct MusicPlayerView: View {
    @Bindable var musicService: MusicPlayerService

    var body: some View {
        VStack(spacing: 16) {
            // Album art
            Group {
                if let art = musicService.albumArt {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)

            // Track info
            VStack(spacing: 4) {
                Text(musicService.trackName.isEmpty ? "Nothing Playing" : musicService.trackName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)

                if !musicService.artistName.isEmpty {
                    Text(musicService.artistName)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            // Transport controls
            HStack(spacing: 28) {
                Button(action: { musicService.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: { musicService.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 48, height: 48)
                        Image(systemName: musicService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.black)
                            .offset(x: musicService.isPlaying ? 0 : 2)
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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
