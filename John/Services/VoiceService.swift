import Foundation
import Speech
import AVFoundation

enum VoiceState: Equatable {
    case idle           // Listening for wake word
    case activated      // Recording user command
    case processing     // Waiting for AI response
    case speaking       // TTS playing response
    case error(String)
    case permissionDenied
}

@Observable
@MainActor
final class VoiceService: NSObject {
    var voiceState: VoiceState = .idle
    var isEnabled: Bool = false
    var activatedTranscript: String = ""

    weak var harness: AgentHarness?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var ttsPlayer: AVAudioPlayer?
    private var ttsPlaybackContinuation: CheckedContinuation<Void, Never>?

    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private var restartTimer: Timer?
    private var isTapInstalled = false
    private var isPausedForSpeaking = false

    override init() {
        super.init()
    }

    // MARK: - Public

    func enable() {
        Task { @MainActor in
            guard await requestPermissions() else { return }
            isEnabled = true
            UserDefaults.standard.set(true, forKey: "voiceEnabled")
            startAudioEngine()
            startWakeWordRecognition()
            scheduleRestartTimer()
        }
    }

    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: "voiceEnabled")
        stopAll()
        voiceState = .idle
    }

    func restoreEnabledState() {
        if UserDefaults.standard.bool(forKey: "voiceEnabled") {
            enable()
        }
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            voiceState = .permissionDenied
            return false
        }

        let micStatus = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micStatus else {
            voiceState = .permissionDenied
            return false
        }

        return true
    }

    // MARK: - Audio Engine

    private func startAudioEngine() {
        guard !audioEngine.isRunning else { return }

        if !isTapInstalled {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, !self.isPausedForSpeaking else { return }
                self.recognitionRequest?.append(buffer)
            }
            isTapInstalled = true
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            voiceState = .error("Audio engine failed: \(error.localizedDescription)")
        }
    }

    private func stopAll() {
        restartTimer?.invalidate()
        restartTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        ttsPlayer?.stop()
        ttsPlayer = nil
        ttsPlaybackContinuation?.resume()
        ttsPlaybackContinuation = nil
    }

    // MARK: - Wake Word Recognition

    private func startWakeWordRecognition() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let transcript = result.bestTranscription.formattedString.lowercased()

                    switch self.voiceState {
                    case .idle:
                        if transcript.contains("hey john") {
                            self.voiceState = .activated
                            self.activatedTranscript = ""
                            NotificationCenter.default.post(name: .WakeWordDetected, object: nil)
                            self.resetSilenceTimer()
                        }
                    case .activated:
                        self.activatedTranscript = transcript
                        self.resetSilenceTimer()
                        if result.isFinal {
                            self.finalizeCommand()
                        }
                    case .processing, .speaking, .error, .permissionDenied:
                        break
                    }
                }
            }

            if let error = error as NSError?, error.code != 301 {
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else { return }
                    if self.voiceState == .activated {
                        self.finalizeCommand()
                    } else if self.voiceState == .idle {
                        self.startRecognitionTask()
                    }
                }
            }
        }
    }

    private func startRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let transcript = result.bestTranscription.formattedString.lowercased()

                    switch self.voiceState {
                    case .idle:
                        if transcript.contains("hey john") {
                            self.voiceState = .activated
                            self.activatedTranscript = ""
                            NotificationCenter.default.post(name: .WakeWordDetected, object: nil)
                            self.resetSilenceTimer()
                        }
                    case .activated:
                        self.activatedTranscript = transcript
                        self.resetSilenceTimer()
                        if result.isFinal {
                            self.finalizeCommand()
                        }
                    case .processing, .speaking, .error, .permissionDenied:
                        break
                    }
                }
            }

            if let error = error as NSError?, error.code != 301 {
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else { return }
                    if self.voiceState == .activated {
                        self.finalizeCommand()
                    } else if self.voiceState == .idle {
                        self.startRecognitionTask()
                    }
                }
            }
        }
    }

    private func scheduleRestartTimer() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.voiceState == .idle, self.isEnabled else { return }
                self.startRecognitionTask()
            }
        }
    }

    // MARK: - Command Recording

    private func transitionToActivated() {
        voiceState = .activated
        activatedTranscript = ""
        NotificationCenter.default.post(name: .WakeWordDetected, object: nil)
        resetSilenceTimer()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.voiceState == .activated else { return }
                self.finalizeCommand()
            }
        }
    }

    private func finalizeCommand() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        var commandText = activatedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading wake word bleed
        let wakeWordPatterns = ["hey john,", "hey john ", "hey john"]
        for pattern in wakeWordPatterns {
            if commandText.lowercased().hasPrefix(pattern) {
                commandText = String(commandText.dropFirst(pattern.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !commandText.isEmpty else {
            voiceState = .idle
            activatedTranscript = ""
            return
        }

        voiceState = .processing

        Task { @MainActor [weak self] in
            guard let self, let harness = self.harness else { return }
            let responseText = await harness.sendStreamingAndWait(commandText)
            if !responseText.isEmpty {
                self.speakResponse(responseText)
            } else {
                voiceState = .idle
                activatedTranscript = ""
            }
        }
    }

    // MARK: - TTS

    private func speakResponse(_ text: String) {
        Task {
            let plainText = stripMarkdown(text)
            await playOpenAITTS(plainText)
        }
    }
    
    private func playOpenAITTS(_ text: String) async {
        voiceState = .speaking
        isPausedForSpeaking = true
        
        do {
            let audioData = try await BackendClient.shared.speakTTS(text: text)
            guard !audioData.isEmpty else {
                print("[TTS] Empty audio response from backend")
                returnToIdle()
                return
            }

            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            ttsPlayer = player

            guard player.play() else {
                print("[TTS] Failed to start audio playback")
                returnToIdle()
                return
            }

            await withCheckedContinuation { continuation in
                self.ttsPlaybackContinuation = continuation
            }
        } catch {
            print("[TTS] Playback error: \(error.localizedDescription)")
            returnToIdle()
        }
    }

    private func finishTTSPlayback() {
        ttsPlaybackContinuation?.resume()
        ttsPlaybackContinuation = nil
        ttsPlayer = nil
        returnToIdle()
    }

    private func returnToIdle() {
        voiceState = .idle
        isPausedForSpeaking = false
        activatedTranscript = ""
    }

    // MARK: - Helpers

    private func stripMarkdown(_ text: String) -> String {
        var result = text
        // Remove code blocks
        result = result.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        // Remove inline code
        result = result.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
        // Remove markdown bold/italic
        result = result.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}", with: "$1", options: .regularExpression)
        // Remove headings
        result = result.replacingOccurrences(of: "#{1,6}\\s", with: "", options: .regularExpression)
        // Remove links
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoiceService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finishTTSPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            if let error {
                print("[TTS] Decode error: \(error.localizedDescription)")
            }
            self?.finishTTSPlayback()
        }
    }
}
