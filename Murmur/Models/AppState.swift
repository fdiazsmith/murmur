import Foundation
import SwiftUI

enum AppRecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case done(String)
    case error(String)
}

enum TranscriptionProviderType: String, CaseIterable {
    case local = "Local (WhisperKit)"
    case cloud = "Cloud (OpenAI)"
}

@MainActor
class AppState: ObservableObject {
    @Published var state: AppRecordingState = .idle
    @Published var selectedProvider: TranscriptionProviderType = .local {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }
    @Published var apiKey: String = "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "openaiAPIKey") }
    }
    @Published var lastTranscription: String = ""

    var pillController: PillWindowController?
    var hotkeyManager: HotkeyManager?

    let audioRecorder = AudioRecorder()

    private var currentProvider: any TranscriptionProvider {
        switch selectedProvider {
        case .local:
            return localTranscriber
        case .cloud:
            return CloudTranscriber(apiKey: apiKey)
        }
    }

    private lazy var localTranscriber = LocalTranscriber()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = TranscriptionProviderType(rawValue: saved) {
            selectedProvider = provider
        }
        apiKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""
    }

    func startRecording() {
        guard state == .idle else {
            print("[Murmur] startRecording skipped, state=\(state)")
            return
        }
        do {
            try audioRecorder.start()
            state = .recording
            print("[Murmur] Recording started")
        } catch {
            print("[Murmur] Mic error: \(error)")
            state = .error("Mic error: \(error.localizedDescription)")
            resetStateAfterDelay()
        }
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else {
            print("[Murmur] stopRecording skipped, state=\(state)")
            return
        }
        guard let fileURL = audioRecorder.stop() else {
            print("[Murmur] No audio file produced")
            state = .error("No audio recorded")
            resetStateAfterDelay()
            return
        }

        print("[Murmur] Recording stopped, file: \(fileURL.lastPathComponent)")
        state = .transcribing
        let provider = currentProvider

        Task {
            do {
                print("[Murmur] Transcribing with \(selectedProvider.rawValue)...")
                let text = try await provider.transcribe(fileURL: fileURL)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    print("[Murmur] Empty transcription")
                    state = .error("Empty transcription")
                    resetStateAfterDelay()
                    return
                }
                print("[Murmur] Transcribed: \(text.prefix(80))")
                lastTranscription = text
                PasteService.paste(text)
                state = .done(text)
                resetStateAfterDelay()
            } catch {
                print("[Murmur] Transcription error: \(error)")
                state = .error("Transcription failed: \(error.localizedDescription)")
                resetStateAfterDelay()
            }
        }
    }

    private func resetStateAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if state != .recording && state != .transcribing {
                state = .idle
            }
        }
    }
}
