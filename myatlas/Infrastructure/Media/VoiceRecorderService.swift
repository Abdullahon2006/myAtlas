import AVFoundation
import Foundation

@MainActor
final class VoiceRecorderService: NSObject, ObservableObject {
    enum VoiceError: LocalizedError {
        case permissionDenied
        case recorderFailed
        case playbackFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Microphone access is needed to record voice notes. You can enable it in Settings."
            case .recorderFailed:
                "Could not start audio recording on this device."
            case .playbackFailed:
                "Could not play this voice note."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var meterSamples: [Float] = []

    @Published private(set) var playingAttachmentID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackCurrentTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var meterTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var isStartingRecording = false
    private var isAudioSessionActive = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        registerAudioSessionObservers()
    }

    deinit {
        meterTask?.cancel()
        playbackTask?.cancel()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: - Recording

    func startRecording() async -> Bool {
        guard !isStartingRecording else { return false }
        if isRecording {
            cancelRecording()
        }
        stopPlayback()
        errorMessage = nil
        isStartingRecording = true
        defer { isStartingRecording = false }

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorMessage = VoiceError.permissionDenied.localizedDescription
            return false
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            isAudioSessionActive = true

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true

            guard newRecorder.record() else {
                throw VoiceError.recorderFailed
            }

            recorder = newRecorder
            recordingURL = tempURL
            isRecording = true
            recordingDuration = 0
            meterSamples = []
            startMeterLoop()
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            deactivateAudioSessionIfNeeded()
            errorMessage = VoiceError.recorderFailed.localizedDescription
            return false
        }
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        meterTask?.cancel()
        meterTask = nil

        guard let recorder, let url = recordingURL else {
            isRecording = false
            return nil
        }

        let duration = max(recorder.currentTime, recordingDuration)
        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        isRecording = false
        deactivateAudioSessionIfNeeded()

        guard duration >= 0.3, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, duration)
    }

    func cancelRecording() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        isRecording = false
        recordingDuration = 0
        meterSamples = []
        deactivateAudioSessionIfNeeded()
    }

    // MARK: - Playback

    func togglePlayback(url: URL, attachmentID: UUID) {
        if playingAttachmentID == attachmentID {
            if isPlaying {
                pausePlayback()
            } else {
                resumePlayback()
            }
            return
        }
        startPlayback(url: url, attachmentID: attachmentID)
    }

    func startPlayback(url: URL, attachmentID: UUID) {
        stopPlayback()
        errorMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            isAudioSessionActive = true

            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            guard audioPlayer.play() else {
                throw VoiceError.playbackFailed
            }

            player = audioPlayer
            playingAttachmentID = attachmentID
            isPlaying = true
            playbackCurrentTime = 0
            playbackDuration = audioPlayer.duration
            startPlaybackLoop()
        } catch {
            deactivateAudioSessionIfNeeded()
            errorMessage = VoiceError.playbackFailed.localizedDescription
        }
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        deactivateAudioSessionIfNeeded()
    }

    func resumePlayback() {
        guard let player else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isAudioSessionActive = true
            if player.play() {
                isPlaying = true
                startPlaybackLoop()
            }
        } catch {
            errorMessage = VoiceError.playbackFailed.localizedDescription
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        playingAttachmentID = nil
        playbackCurrentTime = 0
        playbackDuration = 0
        deactivateAudioSessionIfNeeded()
    }

    private func deactivateAudioSessionIfNeeded() {
        guard isAudioSessionActive else { return }
        isAudioSessionActive = false
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Loops & Notifications

    private func startMeterLoop() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let recorder = self.recorder else { break }
                recorder.updateMeters()
                self.recordingDuration = recorder.currentTime
                let decibels = recorder.averagePower(forChannel: 0)
                let normalized = max(0.08, min(1.0, (decibels + 50) / 50))
                self.meterSamples.append(normalized)
                if self.meterSamples.count > 36 {
                    self.meterSamples.removeFirst(self.meterSamples.count - 36)
                }
            }
        }
    }

    private func startPlaybackLoop() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let player = self.player, self.isPlaying else { break }
                self.playbackCurrentTime = player.currentTime
            }
        }
    }

    private func registerAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .began else {
                    return
                }
                if self.isPlaying {
                    self.pausePlayback()
                }
                if self.isRecording {
                    self.errorMessage = "Recording paused due to an audio interruption."
                    self.cancelRecording()
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let reasonValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable,
                      self.isPlaying else {
                    return
                }
                self.pausePlayback()
            }
        }
    }

    nonisolated static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

extension VoiceRecorderService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                self.errorMessage = VoiceError.recorderFailed.localizedDescription
                self.cancelRecording()
            }
        }
    }
}

extension VoiceRecorderService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopPlayback()
        }
    }
}
