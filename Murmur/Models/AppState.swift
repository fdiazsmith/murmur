import Foundation
import SwiftUI

enum AppRecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case done(String)
    /// Nothing went wrong, but nothing was pasted either ("No speech heard",
    /// "Copied — press ⌘V").
    case notice(String)
    case error(String)

    var isBusy: Bool { self == .recording || self == .transcribing }
}

enum TranscriptionProviderType: String, CaseIterable {
    case local = "Local (WhisperKit)"
    case cloud = "Cloud (OpenAI)"
}

@MainActor
class AppState: ObservableObject {
    @Published var state: AppRecordingState = .idle
    @Published var selectedProvider: TranscriptionProviderType = .local {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider")
            if selectedProvider == .local { warmUpLocalModel() }
        }
    }
    @Published var apiKey: String = "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "openaiAPIKey") }
    }
    @Published var lastTranscription: String = ""
    @Published var recordingElapsedTime: TimeInterval = 0

    /// The dictation being recorded / transcribed.
    private var session: DictationSession?

    /// The transcript so far while a dictation is in progress — shown in the
    /// bubble above the pill.
    @Published var partialText = ""

    /// Show the live transcript bubble (and run preview passes to feed it).
    @Published var livePreview = true {
        didSet { UserDefaults.standard.set(livePreview, forKey: "livePreview") }
    }

    /// Release-to-paste time of the last dictation, shown in the menu.
    @Published var lastLatency: TimeInterval?

    /// Extra capture after release when the speaker was still mid-word, so
    /// the last syllable isn't clipped.
    private static let tailGrace: Duration = .milliseconds(120)

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

    // Whisper model variant (local only)
    @Published var modelVariant: String = WhisperModelCatalog.defaultVariant {
        didSet {
            guard modelVariant != oldValue else { return }
            UserDefaults.standard.set(modelVariant, forKey: Self.modelVariantKey)
            // Drop the old model and load the new one now, so the first
            // dictation after a switch doesn't pay the (large-model) load.
            localTranscriber.modelVariant = modelVariant
            localTranscriber.invalidate()
            warmUpLocalModel()
        }
    }

    static let availableModels = WhisperModelCatalog.variants

    /// Local model load/download status from `LocalTranscriber.onProgress`
    /// ("Loading model…", "Downloading model… 40%", "Ready"); shown under the
    /// model picker.
    @Published var modelStatus: String = ""

    /// The local model is downloading / loading — dictations will wait for it.
    var isModelLoading: Bool { !modelStatus.isEmpty && modelStatus != "Ready" }

    private static let modelVariantKey = "whisperModelVariant"
    /// Set once the upgrade of an earlier default (base, full-size turbo) to
    /// the current default has run, so a user who later picks one of those
    /// deliberately keeps it. The key is versioned per default change.
    private static let modelMigrationKey = "didMigrateModelToCompressedTurbo"

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

    private var currentProvider: any TranscriptionProvider {
        switch selectedProvider {
        case .local: return localTranscriber
        case .cloud: return CloudTranscriber(apiKey: apiKey)
        }
    }

    lazy var localTranscriber: LocalTranscriber = {
        let t = LocalTranscriber()
        t.modelVariant = modelVariant
        t.onProgress = { [weak self] _, status in
            self?.modelStatus = status
        }
        return t
    }()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = TranscriptionProviderType(rawValue: saved) {
            selectedProvider = provider
        }
        apiKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""

        inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        audioRecorder.selectedDeviceUID = inputDeviceUID

        // Property observers don't fire in init, so persist the resolved
        // variant here (it may differ from the stored one after migration).
        let defaults = UserDefaults.standard
        modelVariant = WhisperModelCatalog.resolveStoredVariant(
            defaults.string(forKey: Self.modelVariantKey),
            migrationDone: defaults.bool(forKey: Self.modelMigrationKey)
        )
        defaults.set(modelVariant, forKey: Self.modelVariantKey)
        defaults.set(true, forKey: Self.modelMigrationKey)

        if let saved = UserDefaults.standard.string(forKey: "duckMode"),
           let mode = AudioDuckMode(rawValue: saved) {
            duckMode = mode
        }
        duckLevel = UserDefaults.standard.object(forKey: "duckLevel") as? Float ?? 0.2

        livePreview = UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true

        loadHistory()

        // Load the model at launch so the first dictation isn't the one that
        // waits for it (large-v3 turbo takes seconds to load, minutes to
        // specialize after an OS update).
        warmUpLocalModel()
    }

    /// Start loading the local model in the background. No-op when the cloud
    /// provider is selected or the model is already loaded / loading.
    func warmUpLocalModel() {
        guard selectedProvider == .local, !MicCheck.isRequested else { return }
        let transcriber = localTranscriber
        Task { await transcriber.warmup() }
    }

    func startRecording() {
        // Allow recording from idle, done, or error — only block if actively recording/transcribing
        guard !state.isBusy else {
            print("[Murmur] startRecording skipped, state=\(state)")
            return
        }
        // Cancel any pending reset timer so it can't clobber this new session
        resetTask?.cancel()
        resetTask = nil

        let provider = currentProvider
        partialText = ""
        let sessionBox = WeakSession()
        let onPartial: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] () -> Void in
                self?.showPartial(text, from: sessionBox.session)
            }
        }
        let session = DictationSession(
            provider: provider,
            profilePrompt: selectedProfile.prompt,
            livePreview: livePreview,
            onPartial: livePreview ? onPartial : nil
        )
        sessionBox.session = session
        do {
            audioDucker.duck(mode: duckMode, level: duckLevel)
            audioRecorder.onElapsedTimeUpdate = { [weak self] elapsed in
                Task { @MainActor in self?.recordingElapsedTime = elapsed }
            }
            audioRecorder.onSamples = { [session] samples in
                session.append(samples)
            }
            audioRecorder.onAutoStop = { [weak self] in
                Task { @MainActor in
                    print("[Murmur] Auto-stop: max duration reached")
                    self?.stopRecordingAndTranscribe()
                }
            }
            try audioRecorder.start()
            self.session = session
            recordingElapsedTime = 0
            state = .recording
            // Wake the Neural Engine while the user is still talking.
            if selectedProvider == .local { localTranscriber.prime() }
            print("[Murmur] Recording started (profile: \(selectedProfile.name), provider: \(selectedProvider.rawValue))")
        } catch {
            audioDucker.restore()
            print("[Murmur] Mic error: \(error)")
            state = .error(Permissions.isMicrophoneAuthorized ? "Mic error" : "Mic access needed")
            resetStateAfterDelay()
        }
    }

    /// - Parameter tailCaptured: the caller already kept recording briefly
    ///   after the physical release (the hotkey's release debounce).
    func stopRecordingAndTranscribe(tailCaptured: Bool = false) {
        // Always restore audio — safe even if not ducked
        audioDucker.restore()
        guard state == .recording, let session else {
            print("[Murmur] stopRecording skipped, state=\(state)")
            return
        }
        state = .transcribing
        let releasedAt = Date()

        Task {
            if !tailCaptured, session.trailingSilence < 0.15 {
                try? await Task.sleep(for: Self.tailGrace)
            }
            let duration = audioRecorder.stop()
            defer { self.session = nil }

            guard duration >= AudioRecorder.minimumDuration else {
                print(String(format: "[Murmur] Recording too short (%.2fs), discarding", duration))
                session.cancel()
                finish(with: .notice("Hold to speak"))
                return
            }

            let outcome = await session.finish()
            let latency = Date().timeIntervalSince(releasedAt)
            print(String(
                format: "[Murmur][Timing] dictation: audio %.1fs, %d piece(s), %d failed, ahead=%@, release→text %.2fs",
                outcome.audioDuration, outcome.pieceCount, outcome.failedPieces,
                outcome.finishedAhead ? "yes" : "no", latency
            ))
            deliver(outcome, latency: latency)
        }
    }

    private func showPartial(_ text: String, from source: DictationSession?) {
        // Ignore stragglers from a dictation that is already over.
        guard let source, source === session else { return }
        partialText = text
    }

    private func deliver(_ outcome: DictationSession.Outcome, latency: TimeInterval) {
        if outcome.silent {
            print("[Murmur] Mic delivered silence")
            finish(with: .notice("Mic is silent"))
            return
        }
        guard !outcome.text.isEmpty else {
            if let error = outcome.error {
                print("[Murmur] Transcription failed: \(error)")
                finish(with: .error(Self.shortMessage(for: error)))
            } else {
                print("[Murmur] Empty transcription")
                finish(with: .notice("No speech heard"))
            }
            return
        }

        let text = outcome.text
        let tail = text.count > 160 ? " […] \(text.suffix(80))" : ""
        print("[Murmur] Transcribed \(text.count) chars: \(text.prefix(80))\(tail)")
        if outcome.failedPieces > 0 {
            print("[Murmur] \(outcome.failedPieces) piece(s) failed — transcript is incomplete")
        }
        lastTranscription = text
        lastLatency = latency
        addToHistory(text)
        switch PasteService.paste(text) {
        case .pasted:
            finish(with: .done(text))
        case .copiedOnly:
            _ = Permissions.requestAccessibilityAccess()
            finish(with: .notice("Copied — press ⌘V"), after: .seconds(4))
        }
    }

    private func finish(with newState: AppRecordingState, after delay: Duration = .seconds(2)) {
        partialText = ""
        state = newState
        resetStateAfterDelay(delay)
    }

    /// A pill-sized message for a transcription error.
    private static func shortMessage(for error: Error) -> String {
        if let cloud = error as? CloudTranscriber.CloudTranscriberError {
            switch cloud {
            case .missingAPIKey: return "Add OpenAI API key"
            case .apiError(let status, _): return status == 401 ? "API key rejected" : "OpenAI error \(status)"
            default: return "Cloud error"
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return "No connection" }
        return "Transcription failed"
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
        guard !state.isBusy else { return }
        let captured = CapturedSamples()
        audioRecorder.onSamples = { captured.append($0) }
        do {
            try audioRecorder.start()
            state = .recording
            print("[Murmur][DEBUG] Capture started — recording 3s...")
        } catch {
            print("[Murmur][DEBUG] Capture failed to start: \(error)")
            finish(with: .error("Mic error"))
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            audioRecorder.stop()
            let samples = captured.samples
            let dest = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/murmur_debug.wav")
            do {
                try WavWriter.data(samples: samples).write(to: dest)
                print("[Murmur][DEBUG] Saved \(samples.count) samples → \(dest.path)")
                NSWorkspace.shared.open(dest)
                finish(with: .notice("Saved to Desktop"))
            } catch {
                print("[Murmur][DEBUG] Save failed: \(error)")
                finish(with: .error("Save failed"))
            }
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
                        self.state = .notice("No speech heard")
                    } else {
                        print("[Murmur][DEBUG] Result: \(trimmed)")
                        self.lastTranscription = trimmed
                        self.state = .done(trimmed)
                    }
                } catch {
                    print("[Murmur][DEBUG] Transcription error: \(error)")
                    self.state = .error("Transcription failed")
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

    private func resetStateAfterDelay(_ delay: Duration = .seconds(2)) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if !state.isBusy {
                audioDucker.restore()
                state = .idle
            }
        }
    }
}

private final class WeakSession: @unchecked Sendable {
    weak var session: DictationSession?
}

/// Thread-safe sample accumulator for the debug capture.
private final class CapturedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func append(_ chunk: [Float]) {
        lock.withLock { storage.append(contentsOf: chunk) }
    }

    var samples: [Float] { lock.withLock { storage } }
}
