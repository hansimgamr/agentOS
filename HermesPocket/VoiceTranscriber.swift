import AVFoundation
import Speech
import Observation

@MainActor @Observable
final class VoiceTranscriber {
    var isRecording = false
    var isStarting = false
    private var generation = 0
    private var tapInstalled = false
    var transcript = ""
    var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording && !isStarting else { stop(); return }
        generation += 1
        let attempt = generation
        isStarting = true
        error = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                guard speechStatus == .authorized else { self.error = "Allow Speech Recognition in Settings to dictate."; self.isStarting = false; return }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.generation == attempt else { return }
                        self.isStarting = false
                        guard granted else { self.error = "Allow microphone access in Settings to dictate."; return }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition is unavailable right now."; return }
        guard recognizer.supportsOnDeviceRecognition else { error = "On-device dictation is unavailable for this language."; return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            transcript = ""
            isRecording = true
            let attempt = generation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if let error { self.error = error.localizedDescription }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch { self.error = error.localizedDescription; stop() }
    }

    func stop() {
        generation += 1
        isStarting = false
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
