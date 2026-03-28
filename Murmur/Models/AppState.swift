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

    // Audio input device (nil = system default)
    @Published var inputDeviceUID: String? = nil {
        didSet {
            if let uid = inputDeviceUID {
                UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
            }
            audioRecorder.selectedDeviceUID = inputDeviceUID
        }
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

    /// Cancellable reset timer — prevents stale timers from clobbering active sessions.
    private var resetTask: Task<Void, Never>?

    /// Max transcription retries on transient failure.
    private static let maxRetries = 1

    private var currentProvider: any TranscriptionProvider {
        switch selectedProvider {
        case .local: return localTranscriber
        case .cloud: return CloudTranscriber(apiKey: apiKey)
        }
    }

    lazy var localTranscriber = LocalTranscriber()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = TranscriptionProviderType(rawValue: saved) {
            selectedProvider = provider
        }
        apiKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""

        inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        audioRecorder.selectedDeviceUID = inputDeviceUID

        if let saved = UserDefaults.standard.string(forKey: "duckMode"),
           let mode = AudioDuckMode(rawValue: saved) {
            duckMode = mode
        }
        duckLevel = UserDefaults.standard.object(forKey: "duckLevel") as? Float ?? 0.2

        loadHistory()
    }

    func startRecording() {
        // Allow recording from idle, done, or error — only block if actively recording/transcribing
        guard state != .recording, state != .transcribing else {
            print("[Murmur] startRecording skipped, state=\(state)")
            return
        }
        // Cancel any pending reset timer so it can't clobber this new session
        resetTask?.cancel()
        resetTask = nil
        state = .idle
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
            print("[Murmur] No audio file (too short or empty)")
            state = .error("Recording too short")
            resetStateAfterDelay()
            return
        }

        print("[Murmur] Recording stopped, file: \(fileURL.lastPathComponent)")
        state = .transcribing
        let provider = currentProvider
        let prompt = selectedProfile.prompt
        let providerName = selectedProvider.rawValue
        print("[Murmur] Profile: \(selectedProfile.name), prompt: \(prompt.isEmpty ? "(empty)" : "\"\(prompt.prefix(40))\""), file: \(fileURL.path)")

        Task {
            var lastError: Error?
            for attempt in 0...Self.maxRetries {
                if attempt > 0 {
                    print("[Murmur] Retry \(attempt)/\(Self.maxRetries)...")
                    try? await Task.sleep(for: .milliseconds(300))
                }
                do {
                    print("[Murmur] Transcribing with \(providerName)...")
                    let text = try await provider.transcribe(fileURL: fileURL, prompt: prompt)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        print("[Murmur] Empty transcription")
                        lastError = TranscriptionError.emptyResult
                        continue
                    }
                    print("[Murmur] Transcribed: \(trimmed.prefix(80))")
                    lastTranscription = trimmed
                    addToHistory(trimmed)
                    PasteService.paste(trimmed)
                    state = .done(trimmed)
                    resetStateAfterDelay()
                    return
                } catch {
                    print("[Murmur] Transcription error (attempt \(attempt)): \(error)")
                    lastError = error
                }
            }
            // All attempts failed — try debug fallback with empty prompt
            print("[Murmur][DEBUG] Fallback: transcribing same file with empty prompt...")
            do {
                let fallback = try await localTranscriber.transcribe(fileURL: fileURL, prompt: "")
                let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("[Murmur][DEBUG] Fallback succeeded: \(trimmed.prefix(80))")
                    lastTranscription = trimmed
                    addToHistory(trimmed)
                    PasteService.paste(trimmed)
                    state = .done(trimmed)
                    resetStateAfterDelay()
                    return
                }
                print("[Murmur][DEBUG] Fallback also empty")
            } catch {
                print("[Murmur][DEBUG] Fallback error: \(error)")
            }
            let message = lastError?.localizedDescription ?? "Unknown error"
            state = .error("Transcription failed: \(message)")
            resetStateAfterDelay()
        }
    }

    private enum TranscriptionError: Error, LocalizedError {
        case emptyResult
        var errorDescription: String? { "Empty transcription" }
    }

    func clearHistory() {
        history.removeAll()
    }

    func resetPillPosition() {
        PillWindowController.clearPosition()
        if let panel = pillController?.panel, let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.maxX - panel.frame.width - 20 + 40
            let y = visibleFrame.minY + 80 - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
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

    // MARK: - Debug

    /// Records 3 seconds to Desktop and opens the file for inspection.
    func debugCapture() {
        state = .idle
        do {
            try audioRecorder.start()
            state = .recording
            print("[Murmur][DEBUG] Capture started — recording 3s...")
        } catch {
            print("[Murmur][DEBUG] Capture failed to start: \(error)")
            state = .error("Debug capture failed: \(error.localizedDescription)")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let tmpURL = audioRecorder.stop() else {
                print("[Murmur][DEBUG] No audio file produced")
                state = .error("Debug: no audio captured")
                resetStateAfterDelay()
                return
            }
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let dest = desktop.appendingPathComponent("murmur_debug.wav")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: tmpURL, to: dest)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let size = (attrs?[.size] as? UInt64) ?? 0
                print("[Murmur][DEBUG] Saved \(size) bytes → \(dest.path)")
                NSWorkspace.shared.open(dest)
                state = .done("Debug: saved to Desktop")
            } catch {
                print("[Murmur][DEBUG] Copy failed: \(error)")
                state = .error("Debug: \(error.localizedDescription)")
            }
            resetStateAfterDelay()
        }
    }

    /// Transcribes a known-good WAV file to test WhisperKit in isolation.
    func debugTranscribe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .audio]
        panel.message = "Select a WAV file to transcribe"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.state = .transcribing
                print("[Murmur][DEBUG] Transcribing: \(url.lastPathComponent)")
                do {
                    let text = try await self.localTranscriber.transcribe(fileURL: url, prompt: "")
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        print("[Murmur][DEBUG] WhisperKit returned empty text")
                        self.state = .error("Debug: empty transcription")
                    } else {
                        print("[Murmur][DEBUG] Result: \(trimmed)")
                        self.lastTranscription = trimmed
                        self.state = .done(trimmed)
                    }
                } catch {
                    print("[Murmur][DEBUG] Transcription error: \(error)")
                    self.state = .error("Debug: \(error.localizedDescription)")
                }
                self.resetStateAfterDelay()
            }
        }
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
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if state != .recording && state != .transcribing {
                audioDucker.restore()
                state = .idle
            }
        }
    }
}
