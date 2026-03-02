import AVFAudio
import SwiftUI

final class SpeechDemoViewModel: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var text: String = "Welcome to the AVFAudio speech synthesis demo."
    @Published var isSpeaking = false
    @Published var rate: Double = 0.5
    @Published var pitch: Double = 1.0

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SpeechDemoViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $viewModel.text)
                        .frame(minHeight: 130)
                }

                Section("Voice") {
                    VStack(alignment: .leading) {
                        Text("Rate: \(viewModel.rate, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.rate, in: 0.3...0.6)
                    }

                    VStack(alignment: .leading) {
                        Text("Pitch: \(viewModel.pitch, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.pitch, in: 0.5...2.0)
                    }
                }

                Section {
                    HStack {
                        Button("Speak") {
                            viewModel.speak()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Stop", role: .destructive) {
                            viewModel.stop()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.isSpeaking)
                    }
                }
            }
            .navigationTitle("AVFAudio Demo")
        }
    }
}
