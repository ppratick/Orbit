import Foundation
import Observation
import AVFAudio
@preconcurrency import Speech

@MainActor @Observable final class OrbitDictation {
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var isFinishing = false
    private(set) var transcript = ""
    private(set) var completedText: String?
    var error: String?
    private(set) var needsSettings = false
    var isBusy: Bool { isStarting || isRecording || isFinishing }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var audioSessionActive = false
    @ObservationIgnored private var sendWhenFinished = false

    func start() async {
        guard !isBusy else { return }
        cancel()
        let id = sessionID
        transcript = ""; completedText = nil; error = nil; needsSettings = false; isStarting = true
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        guard id == sessionID else { return }
        guard authorization == .authorized else {
            needsSettings = true
            fail("Allow Speech Recognition for Orbit in iPhone Settings to dictate a question.")
            return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard id == sessionID else { return }
        guard microphone else {
            needsSettings = true
            fail("Allow microphone access for Orbit in iPhone Settings to dictate a question.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail("Speech recognition is unavailable right now. Please try again or type your question.")
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            audioSessionActive = true
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw DictationError.microphoneUnavailable
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.engine = engine; self.request = request
            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in self?.receive(text, final: final, failed: failed, id: id) }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            isStarting = false; isRecording = true
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.sessionID == id else { return }
                if self.transcript.isEmpty { self.fail("I didn't hear a question. Tap the microphone and try again."); return }
                try? await Task.sleep(for: .seconds(43))
                guard !Task.isCancelled, self.sessionID == id else { return }
                self.finish()
            }
        } catch {
            fail("Couldn't start the microphone. End any active call or recording, then try again.")
        }
    }
    /// Stopping keeps the transcript; only an explicit Send action requests submission.
    func finish(send: Bool = false) {
        guard isRecording || isFinishing else { return }
        sendWhenFinished = sendWhenFinished || send
        guard isRecording else { return }
        isRecording = false; isFinishing = true
        timeout?.cancel()
        stopAudio()
        request?.endAudio()
        let id = sessionID
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.complete()
        }
    }
    func cancel() {
        sessionID = UUID()
        timeout?.cancel(); timeout = nil
        stopAudio()
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        isRecording = false; isStarting = false; isFinishing = false
        sendWhenFinished = false
    }
    private func receive(_ text: String?, final: Bool, failed: Bool, id: UUID) {
        guard id == sessionID, isBusy else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = String(text.prefix(4000))
        }
        if final { complete() }
        else if failed {
            if isFinishing { complete() }
            else { fail("Dictation was interrupted. Your words are in the input below; review them before sending.") }
        }
    }
    private func complete() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSend = sendWhenFinished
        cancel() // Invalidates late callbacks, preventing a second send.
        if shouldSend { completedText = text }
    }
    private func fail(_ message: String) { cancel(); error = message }
    private func stopAudio() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }
    private enum DictationError: Error { case microphoneUnavailable }
}
