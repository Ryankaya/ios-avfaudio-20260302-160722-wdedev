import AVFAudio
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechDemoViewModel: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var text: String = "Tap Listen and speak to transcribe your voice."
    @Published var isSpeaking = false
    @Published var isListening = false
    @Published var rate: Double = 0.5
    @Published var pitch: Double = 1.0
    @Published var statusMessage = "Ready."

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak() {
        stopListening(status: "Stopped listening.")

        guard !trimmedText.isEmpty else {
            statusMessage = "Enter text before speaking."
            return
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.voice = resolvedVoice()

        synthesizer.speak(utterance)
        isSpeaking = true
        statusMessage = "Speaking..."
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        statusMessage = "Stopped speaking."
    }

    func toggleListening() {
        if isListening {
            stopListening(status: "Stopped listening.")
        } else {
            Task {
                await startListening()
            }
        }
    }

    private func startListening() async {
        stopSpeaking()

        guard let recognizer = speechRecognizer else {
            statusMessage = "Speech recognizer unavailable for current locale."
            return
        }

        guard recognizer.isAvailable else {
            statusMessage = "Speech recognizer is temporarily unavailable."
            return
        }

        let speechAuthorized = await requestSpeechAuthorization()
        guard speechAuthorized else {
            statusMessage = "Enable Speech Recognition permission in Settings."
            return
        }

        let micAuthorized = await requestMicrophoneAuthorizationIfNeeded()
        guard micAuthorized else {
            statusMessage = "Enable Microphone permission in Settings."
            return
        }

        do {
            try configureAudioSession()
            try beginRecognition(with: recognizer)
            isListening = true
            statusMessage = "Listening..."
        } catch {
            stopListening(status: "Could not start listening: \(error.localizedDescription)")
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func beginRecognition(with recognizer: SFSpeechRecognizer) throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stopListening(status: "Transcription complete.")
                    }
                }

                if let error {
                    self.stopListening(status: "Listening failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopListening(status: String) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        isListening = false
        statusMessage = status
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.statusMessage = "Finished speaking."
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.statusMessage = "Cancelled speaking."
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let preferred = Locale.preferredLanguages.first,
           !preferred.isEmpty,
           let voice = AVSpeechSynthesisVoice(language: preferred) {
            return voice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SpeechDemoViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcription") {
                    TextEditor(text: $viewModel.text)
                        .frame(minHeight: 160)
                }

                Section("Speech Output") {
                    VStack(alignment: .leading) {
                        Text("Rate: \(viewModel.rate, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.rate, in: 0.3...0.6)
                    }

                    VStack(alignment: .leading) {
                        Text("Pitch: \(viewModel.pitch, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.pitch, in: 0.5...2.0)
                    }
                }

                Section("Status") {
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    Button(viewModel.isListening ? "Stop Listening" : "Listen") {
                        viewModel.toggleListening()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.isListening ? .orange : .blue)

                    Button("Speak Text") {
                        viewModel.speak()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Stop Speaking", role: .destructive) {
                        viewModel.stopSpeaking()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isSpeaking)
                }
            }
            .navigationTitle("AVFAudio + Speech")
        }
    }
}
