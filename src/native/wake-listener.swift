import Speech
import AVFoundation
import Foundation
import AppKit

/// Continuously listens to the microphone using SFSpeechRecognizer.
/// Outputs JSON lines to stdout:
///   {"type":"transcript","text":"...","final":true/false}
///   {"type":"status","message":"..."}
///   {"type":"error","message":"..."}
///
/// The parent process (Bun) is responsible for detecting the wake phrase
/// in the transcript stream and deciding what to do with commands.

class WakeListener: NSObject, SFSpeechRecognitionTaskDelegate {
    private let speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private let maxRecognitionDuration: TimeInterval = 55 // restart before 60s limit
    private var hasEmittedInitialStatus = false
    private var consecutiveQuickRestarts = 0
    private var lastStartTime: Date = Date()

    override init() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            fatalError("Speech recognizer not available for en-US")
        }
        self.speechRecognizer = recognizer
        super.init()
    }

    func start() {
        // Check if speech recognizer is even available before starting
        guard speechRecognizer.isAvailable else {
            emit(type: "error", message: "Speech recognizer is not available on this system")
            exit(1)
        }

        emit(type: "status", message: "Speech recognizer available, starting directly")

        // Skip explicit permission requests — they crash standalone binaries.
        // Instead, just start listening. macOS will either:
        // 1. Allow it (if permissions were previously granted via System Settings)
        // 2. Show a permission dialog (if running as proper app)
        // 3. Fail with a catchable error
        startListening()
    }

    private func startListening() {
        // Stop any existing session
        stopListening()

        let inputNode = audioEngine.inputNode

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            emit(type: "error", message: "No audio input available")
            // Retry after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startListening()
            }
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            emit(type: "error", message: "Failed to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Use on-device recognition if available (lower latency, no network needed)
        if #available(macOS 13.0, *) {
            recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
            if speechRecognizer.supportsOnDeviceRecognition && !hasEmittedInitialStatus {
                emit(type: "status", message: "Using on-device recognition")
            }
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                self.emitTranscript(text: text, isFinal: isFinal)

                if isFinal {
                    // Recognition ended naturally, restart
                    self.restartListening()
                }
            }

            if let error = error {
                let nsError = error as NSError
                // Ignore "no speech detected" errors — just restart
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                    self.restartListening()
                    return
                }
                // Ignore cancellation errors (we trigger these ourselves)
                if nsError.code == 216 || nsError.code == 209 {
                    return
                }
                self.emit(type: "error", message: error.localizedDescription)
                self.restartListening()
            }
        }

        // Install audio tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        lastStartTime = Date()

        do {
            audioEngine.prepare()
            try audioEngine.start()
            if !hasEmittedInitialStatus {
                emit(type: "status", message: "listening")
                hasEmittedInitialStatus = true
            }
        } catch {
            emit(type: "error", message: "Audio engine failed: \(error.localizedDescription)")
            restartListening()
            return
        }

        // Schedule restart before the ~60 second limit
        restartTimer = Timer.scheduledTimer(withTimeInterval: maxRecognitionDuration, repeats: false) { [weak self] _ in
            self?.restartListening()
        }
    }

    private func stopListening() {
        restartTimer?.invalidate()
        restartTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func restartListening() {
        stopListening()

        // Detect rapid restarts (session lasted < 2 seconds) and back off
        let sessionDuration = Date().timeIntervalSince(lastStartTime)
        let delay: TimeInterval
        if sessionDuration < 2.0 {
            consecutiveQuickRestarts += 1
            // Exponential backoff: 1s, 2s, 4s, max 10s
            delay = min(Double(1 << min(consecutiveQuickRestarts, 3)), 10.0)
        } else {
            consecutiveQuickRestarts = 0
            delay = 0.3
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startListening()
        }
    }

    // MARK: - JSON Output

    private func emit(type: String, message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = "{\"type\":\"\(type)\",\"message\":\"\(escaped)\"}"
        print(json)
        fflush(stdout)
    }

    private func emitTranscript(text: String, isFinal: Bool) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = "{\"type\":\"transcript\",\"text\":\"\(escaped)\",\"final\":\(isFinal)}"
        print(json)
        fflush(stdout)
    }
}

// MARK: - App Delegate (needed for TCC permission dialogs)

class AppDelegate: NSObject, NSApplicationDelegate {
    let listener = WakeListener()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — we're a background helper
        NSApp.setActivationPolicy(.accessory)
        listener.start()
    }
}

// MARK: - Main

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
