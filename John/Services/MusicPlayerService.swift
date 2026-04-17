import AppKit
import Combine
import SwiftUI

enum RepeatMode: Int {
    case off = 1, one = 2, all = 3

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

@Observable
class MusicPlayerService {
    var isPlaying: Bool = false
    var trackName: String = ""
    var artistName: String = ""
    var albumArt: NSImage? = nil
    var hasNowPlaying: Bool = false
    var elapsedTime: Double = 0
    var duration: Double = 0
    var shuffleMode: Bool = false
    var repeatMode: RepeatMode = .off

    private typealias MRMediaRemoteGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFn = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool
    private typealias MRMediaRemoteRegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias MRMediaRemoteSetElapsedTimeFn = @convention(c) (Double) -> Void
    private typealias MRMediaRemoteSetShuffleModeFn = @convention(c) (Int32) -> Void
    private typealias MRMediaRemoteSetRepeatModeFn = @convention(c) (Int32) -> Void

    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFn?
    private var sendCommand: MRMediaRemoteSendCommandFn?
    private var setElapsedTimeFn: MRMediaRemoteSetElapsedTimeFn?
    private var setShuffleModeFn: MRMediaRemoteSetShuffleModeFn?
    private var setRepeatModeFn: MRMediaRemoteSetRepeatModeFn?
    private var nowPlayingObservers: [Any] = []

    private var elapsedTimeAtFetch: Double = 0
    private var fetchTimestamp: Date = Date()
    private var playbackRate: Double = 0
    private var progressTimer: Timer?

    private let kCommandTogglePlayPause: UInt32 = 2
    private let kCommandNextTrack: UInt32 = 4
    private let kCommandPreviousTrack: UInt32 = 5
    private let kCommandToggleShuffle: UInt32 = 12
    private let kCommandToggleRepeat: UInt32 = 13

    init() {
        loadMediaRemote()
        registerForNotifications()
        fetchNowPlaying()
    }

    private func loadMediaRemote() {
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
        if let ptr = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFn = unsafeBitCast(ptr, to: MRMediaRemoteSetElapsedTimeFn.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteSetShuffleMode") {
            setShuffleModeFn = unsafeBitCast(ptr, to: MRMediaRemoteSetShuffleModeFn.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteSetRepeatMode") {
            setRepeatModeFn = unsafeBitCast(ptr, to: MRMediaRemoteSetRepeatModeFn.self)
        }
    }

    private func registerForNotifications() {
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
            "kMRMediaRemotePlayerIsPlayingDidChangeNotification"
        ]
        nowPlayingObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in self?.fetchNowPlaying() }
        }
    }

    func fetchNowPlaying() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            let dur = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            let shuffle = (info["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? Int ?? 0) != 0
            let repeatRaw = info["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? Int ?? 1

            self.trackName = title
            self.artistName = artist
            self.playbackRate = rate
            self.isPlaying = rate > 0
            self.hasNowPlaying = !title.isEmpty
            self.elapsedTimeAtFetch = elapsed
            self.fetchTimestamp = Date()
            self.duration = dur
            self.elapsedTime = elapsed
            self.shuffleMode = shuffle
            self.repeatMode = RepeatMode(rawValue: repeatRaw) ?? .off

            if let artData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                self.albumArt = NSImage(data: artData)
            } else {
                self.albumArt = nil
            }

            self.updateProgressTimer()
        }
    }

    private func updateProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        guard isPlaying && duration > 0 else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = self.elapsedTimeAtFetch + Date().timeIntervalSince(self.fetchTimestamp) * self.playbackRate
            self.elapsedTime = min(elapsed, self.duration)
        }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsedTime / duration, 1.0)
    }

    func seek(to fraction: Double) {
        let time = fraction * duration
        setElapsedTimeFn?(time)
        elapsedTime = time
        elapsedTimeAtFetch = time
        fetchTimestamp = Date()
    }

    func togglePlayPause() {
        _ = sendCommand?(kCommandTogglePlayPause, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fetchNowPlaying() }
    }

    func nextTrack() {
        _ = sendCommand?(kCommandNextTrack, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fetchNowPlaying() }
    }

    func previousTrack() {
        _ = sendCommand?(kCommandPreviousTrack, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fetchNowPlaying() }
    }

    func toggleShuffle() {
        shuffleMode.toggle()
        setShuffleModeFn?(shuffleMode ? 1 : 0)
    }

    func toggleRepeat() {
        repeatMode = repeatMode.next
        setRepeatModeFn?(Int32(repeatMode.rawValue))
    }
}

extension Double {
    var formattedDuration: String {
        let total = Int(self)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
