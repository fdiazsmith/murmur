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

    // v0.1.0: Transcription history
    @Published var history: [TranscriptionEntry] = [] {
        didSet { persistHistory() }
    }

    // Configurable hotkey
    @Published var hotkeyConfig: HotkeyConfig = HotkeyConfig.load() {
        didSet { hotkeyManager?.updateConfig(hotkeyConfig) }
    }

    // Profiles
    @Published var profiles: [Profile] = Profile.loadAll() {
        didSet { Profile.saveAll(profiles) }
    }
    @Published var selectedProfileId: UUID = Profile.loadSelectedId() {
        didSet { Profile.saveSelectedId(selectedProfileId) }
    }

    var selectedProfile: Profile {
        profiles.first(where: { $0.id == selectedProfileId }) ?? profiles.first ?? .general
    }

    // v0.1.0: Audio ducking
    @Published var duckMode: AudioDuckMode = .autoDuck {
        didSet { UserDefaults.standard.set(duckMode.rawValue, forKey: "duckMode") }
    }
    @Published var duckLevel: Float = 0.2 {
        didSet { UserDefaults.standard.set(duckLevel, forKey: "duckLevel") }
    }

    // v0.1.0: Update checker
    @Published var updateAvailable: AvailableUpdate?

    // Controllers (retained)
    var pillController: PillWindowController?
    var hotkeyManager: HotkeyManager?
    var feedbackController: FeedbackWindowController?
    var hotkeyRecorderController: HotkeyRecorderWindowController?
    var profileEditorController: ProfileEditorWindowController?

    let audioRecorder = AudioRecorder()
    let audioDucker = AudioDucker()

    private var currentProvider: any TranscriptionProvider {
        switch selectedProvider {
        case .local: return localTranscriber
        case .cloud: return CloudTranscriber(apiKey: apiKey)
        }
    }

    private lazy var localTranscriber = LocalTranscriber()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = TranscriptionProviderType(rawValue: saved) {
            selectedProvider = provider
        }
        apiKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""

        if let saved = UserDefaults.standard.string(forKey: "duckMode"),
           let mode = AudioDuckMode(rawValue: saved) {
            duckMode = mode
        }
        duckLevel = UserDefaults.standard.object(forKey: "duckLevel") as? Float ?? 0.2

        loadHistory()
    }

    func startRecording() {
        guard state == .idle else {
            print("[Murmur] startRecording skipped, state=\(state)")
            return
        }
        do {
            audioDucker.duck(mode: duckMode, level: duckLevel)
            try audioRecorder.start()
            state = .recording
            print("[Murmur] Recording started")
        } catch {
            audioDucker.restore()
            print("[Murmur] Mic error: \(error)")
            state = .error("Mic error: \(error.localizedDescription)")
            resetStateAfterDelay()
        }
    }

    func stopRecordingAndTranscribe() {
        // Always restore audio — safe even if not ducked
        audioDucker.restore()
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
                let text = try await provider.transcribe(fileURL: fileURL, prompt: selectedProfile.prompt)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    print("[Murmur] Empty transcription")
                    state = .error("Empty transcription")
                    resetStateAfterDelay()
                    return
                }
                print("[Murmur] Transcribed: \(text.prefix(80))")
                lastTranscription = text
                addToHistory(text)
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

    func clearHistory() {
        history.removeAll()
    }

    func checkForUpdates() {
        Task {
            updateAvailable = await UpdateChecker.checkIfNeeded()
            if let update = updateAvailable {
                print("[Murmur] Update available: v\(update.version)")
            }
        }
    }

    @Published var feedbackType: IssueType = .bug

    func showProfileEditor(profile: Profile? = nil) {
        if profileEditorController == nil {
            profileEditorController = ProfileEditorWindowController(appState: self)
        }
        profileEditorController?.show(profile: profile)
    }

    func showHotkeyRecorder() {
        if hotkeyRecorderController == nil {
            hotkeyRecorderController = HotkeyRecorderWindowController(appState: self)
        }
        hotkeyRecorderController?.show()
    }

    // MARK: - Profiles

    func addProfile(name: String, prompt: String) {
        let profile = Profile(id: UUID(), name: name, prompt: prompt)
        profiles.append(profile)
        selectedProfileId = profile.id
    }

    func updateProfile(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
    }

    func deleteProfile(_ profile: Profile) {
        guard profile.id != Profile.general.id else { return }
        profiles.removeAll(where: { $0.id == profile.id })
        if selectedProfileId == profile.id {
            selectedProfileId = profiles.first?.id ?? Profile.general.id
        }
    }

    func showFeedback(type: IssueType = .bug) {
        feedbackType = type
        if feedbackController == nil {
            feedbackController = FeedbackWindowController(appState: self)
        }
        feedbackController?.show()
    }

    // MARK: - Private

    private func addToHistory(_ text: String) {
        let entry = TranscriptionEntry(text: text)
        history.insert(entry, at: 0)
        if history.count > 10 {
            history = Array(history.prefix(10))
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "transcriptionHistory")
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "transcriptionHistory"),
           let saved = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) {
            history = saved
        }
    }

    private func resetStateAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if state != .recording && state != .transcribing {
                // Safety net: restore audio if still ducked
                audioDucker.restore()
                state = .idle
            }
        }
    }
}
