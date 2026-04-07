import AppKit
import SwiftUI

@Observable
class MusicPlayerService {
    var isPlaying: Bool = false
    var trackName: String = ""
    var artistName: String = ""
    var albumArt: NSImage? = nil
    var hasNowPlaying: Bool = false

    // MediaRemote function types
    private typealias MRMediaRemoteGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFn = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool
    private typealias MRMediaRemoteRegisterFn = @convention(c) (DispatchQueue) -> Void

    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFn?
    private var sendCommand: MRMediaRemoteSendCommandFn?
    private var nowPlayingObservers: [Any] = []

    // MRMediaRemote command constants
    private let kCommandTogglePlayPause: UInt32 = 2
    private let kCommandNextTrack: UInt32 = 4
    private let kCommandPreviousTrack: UInt32 = 5

    init() {
        loadMediaRemote()
        registerForNotifications()
        fetchNowPlaying()
    }

    private func loadMediaRemote() {
        // Use dlopen on the dylib directly — more reliable than CFBundleCreate
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return }

        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFn.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(ptr, to: MRMediaRemoteSendCommandFn.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            let register = unsafeBitCast(ptr, to: MRMediaRemoteRegisterFn.self)
            register(DispatchQueue.main)
        }
    }

    private func registerForNotifications() {
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
            "kMRMediaRemotePlayerIsPlayingDidChangeNotification"
        ]
        // Keep all observers — previously only the last was retained
        nowPlayingObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.fetchNowPlaying()
            }
        }
    }

    func fetchNowPlaying() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let playing = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

            self.trackName = title
            self.artistName = artist
            self.isPlaying = playing
            self.hasNowPlaying = !title.isEmpty

            if let artData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                self.albumArt = NSImage(data: artData)
            } else {
                self.albumArt = nil
            }
        }
    }

    func togglePlayPause() {
        _ = sendCommand?(kCommandTogglePlayPause, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func nextTrack() {
        _ = sendCommand?(kCommandNextTrack, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.fetchNowPlaying()
        }
    }

    func previousTrack() {
        _ = sendCommand?(kCommandPreviousTrack, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.fetchNowPlaying()
        }
    }
}
