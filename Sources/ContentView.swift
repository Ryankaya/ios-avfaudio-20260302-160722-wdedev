import AVFAudio
import AVFoundation
import Speech
import SwiftUI
import UIKit
import Vision

@MainActor
final class SpeechStudioViewModel: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var transcript: String = ""
    @Published var liveTranscript: String = ""
    @Published var imageDetails: String = ""
    @Published var selectedImage: UIImage?
    @Published var statusMessage: String = "Ready."
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var isAnalyzingImage = false
    @Published var speechRate: Double = 0.5
    @Published var speechPitch: Double = 1.0

    private let transcriptKey = "speech_studio_transcript"

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var baseTranscriptForSession = ""
    private var latestPartialTranscript = ""

    override init() {
        super.init()
        synthesizer.delegate = self

        let stored = UserDefaults.standard.string(forKey: transcriptKey) ?? ""
        transcript = stored
    }

    func updateTranscript(_ value: String) {
        transcript = value
        persistTranscript()
    }

    func clearTranscript() {
        transcript = ""
        persistTranscript()
        statusMessage = "Transcript cleared."
    }

    func toggleListening() {
        if isListening {
            stopListening(reason: "Stopped listening.")
        } else {
            Task {
                await startListening()
            }
        }
    }

    func speakTranscript() {
        speak(trimmed(transcript), emptyMessage: "Add transcript text before speaking.")
    }

    func speakImageDetails() {
        speak(trimmed(imageDetails), emptyMessage: "Capture a photo first, then analyze it.")
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        statusMessage = "Stopped speaking."
    }

    func analyzeImage(_ image: UIImage) {
        selectedImage = image
        imageDetails = ""
        isAnalyzingImage = true
        statusMessage = "Analyzing image..."

        Task {
            do {
                let details = try await extractImageDetails(from: image)
                imageDetails = details
                statusMessage = "Image details ready."
            } catch {
                imageDetails = ""
                statusMessage = "Image analysis failed: \(error.localizedDescription)"
            }

            isAnalyzingImage = false
        }
    }

    private func speak(_ content: String, emptyMessage: String) {
        stopListening(reason: "Stopped listening.")

        guard !content.isEmpty else {
            statusMessage = emptyMessage
            return
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: content)
        utterance.rate = Float(speechRate)
        utterance.pitchMultiplier = Float(speechPitch)
        utterance.voice = resolvedVoice()

        synthesizer.speak(utterance)
        isSpeaking = true
        statusMessage = "Speaking..."
    }

    private func startListening() async {
        stopSpeaking()

        guard let recognizer = speechRecognizer else {
            statusMessage = "Speech recognizer unavailable for this locale."
            return
        }

        guard recognizer.isAvailable else {
            statusMessage = "Speech recognizer is temporarily unavailable."
            return
        }

        guard await requestSpeechAuthorization() else {
            statusMessage = "Enable Speech Recognition permission in Settings."
            return
        }

        guard await requestMicrophoneAuthorizationIfNeeded() else {
            statusMessage = "Enable Microphone permission in Settings."
            return
        }

        do {
            baseTranscriptForSession = trimmed(transcript)
            latestPartialTranscript = ""
            liveTranscript = ""

            try configureAudioSession()
            try beginRecognition(with: recognizer)
            isListening = true
            statusMessage = "Listening..."
        } catch {
            finalizeListening(status: "Could not start listening: \(error.localizedDescription)")
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
                    self.latestPartialTranscript = result.bestTranscription.formattedString
                    self.liveTranscript = self.latestPartialTranscript
                    self.transcript = self.combinedTranscript(base: self.baseTranscriptForSession, newSegment: self.latestPartialTranscript)

                    if result.isFinal {
                        self.finalizeListening(status: "Transcription saved.")
                        return
                    }
                }

                if let error {
                    self.finalizeListening(status: "Listening stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finalizeListening(status: String) {
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

        transcript = combinedTranscript(base: baseTranscriptForSession, newSegment: latestPartialTranscript)
        persistTranscript()

        liveTranscript = ""
        isListening = false
        statusMessage = status
    }

    func stopListening(reason: String) {
        guard isListening || audioEngine.isRunning || recognitionTask != nil else { return }
        finalizeListening(status: reason)
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

    private func extractImageDetails(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "SpeechStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read selected image."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if lines.isEmpty {
                    continuation.resume(returning: "No readable text detected in the image.")
                    return
                }

                let details = lines.prefix(12).joined(separator: "\n")
                continuation.resume(returning: details)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func persistTranscript() {
        UserDefaults.standard.setValue(transcript, forKey: transcriptKey)
    }

    private func combinedTranscript(base: String, newSegment: String) -> String {
        let cleanBase = trimmed(base)
        let cleanSegment = trimmed(newSegment)

        guard !cleanSegment.isEmpty else { return cleanBase }
        guard !cleanBase.isEmpty else { return cleanSegment }

        return "\(cleanBase)\n\n\(cleanSegment)"
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let preferred = Locale.preferredLanguages.first,
           !preferred.isEmpty,
           let voice = AVSpeechSynthesisVoice(language: preferred) {
            return voice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SpeechStudioViewModel()
    @State private var showingSourceDialog = false
    @State private var showingImagePicker = false
    @State private var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    transcriptCard
                    voiceCaptureCard
                    imageCard
                    playbackCard
                    statusCard
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.98, green: 0.99, blue: 1.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Voice Notes Studio")
            .confirmationDialog("Add Photo", isPresented: $showingSourceDialog) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        imagePickerSource = .camera
                        showingImagePicker = true
                    }
                }

                Button("Choose from Library") {
                    imagePickerSource = .photoLibrary
                    showingImagePicker = true
                }

                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(sourceType: imagePickerSource) { image in
                    viewModel.analyzeImage(image)
                }
            }
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    viewModel.clearTranscript()
                }
                .font(.subheadline)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(
                    text: Binding(
                        get: { viewModel.transcript },
                        set: { viewModel.updateTranscript($0) }
                    )
                )
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if viewModel.transcript.isEmpty {
                    Text("Tap Listen and start speaking. Your text will persist here.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            if !viewModel.liveTranscript.isEmpty {
                Text("Live: \(viewModel.liveTranscript)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var voiceCaptureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice Capture")
                .font(.headline)

            Text("Tap Listen, speak clearly, then stop. Final text stays in Transcript.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(viewModel.isListening ? "Stop Listening" : "Listen") {
                viewModel.toggleListening()
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isListening ? .orange : .blue)
        }
        .cardStyle()
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photo Details")
                    .font(.headline)
                Spacer()
                Button("Add Photo") {
                    showingSourceDialog = true
                }
                .buttonStyle(.bordered)
            }

            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if viewModel.isAnalyzingImage {
                HStack {
                    ProgressView()
                    Text("Analyzing image...")
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.imageDetails.isEmpty {
                ScrollView {
                    Text(viewModel.imageDetails)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 140)
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button("Speak Image Details") {
                    viewModel.speakImageDetails()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            } else {
                Text("Add a photo to extract text details and listen to them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback")
                .font(.headline)

            VStack(alignment: .leading) {
                Text("Rate: \(viewModel.speechRate, format: .number.precision(.fractionLength(2)))")
                Slider(value: $viewModel.speechRate, in: 0.3...0.6)
            }

            VStack(alignment: .leading) {
                Text("Pitch: \(viewModel.speechPitch, format: .number.precision(.fractionLength(2)))")
                Slider(value: $viewModel.speechPitch, in: 0.5...2.0)
            }

            HStack {
                Button("Speak Transcript") {
                    viewModel.speakTranscript()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Stop", role: .destructive) {
                    viewModel.stopSpeaking()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isSpeaking)
            }
        }
        .cardStyle()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)
            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.99, green: 1.0, blue: 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

private extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker

        init(parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
