import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @State private var showUninstallConfirmation = false
    @State private var copiedEntryId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Update banner
            if let update = appState.updateAvailable {
                Button("Update available: v\(update.version)") {
                    NSWorkspace.shared.open(update.downloadURL)
                }
                .foregroundStyle(.blue)
                Divider()
            }

            statusSection
            Divider()
            profileSection
            Divider()
            providerSection
            Divider()
            hotkeySection
            Divider()
            audioSection
            Divider()
            historySection
            Divider()
            feedbackSection
            Divider()
            Button("Uninstall Murmur...") {
                showUninstallConfirmation = true
            }
            Button("Quit Murmur") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
        .alert("Uninstall Murmur?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { Self.uninstall() }
        } message: {
            Text("This will remove Murmur from Applications, clear its settings, and quit.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.headline)
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        Picker("Provider", selection: $appState.selectedProvider) {
            ForEach(TranscriptionProviderType.allCases, id: \.self) { type in
                Text(type.rawValue).tag(type)
            }
        }
        if appState.selectedProvider == .cloud {
            SecureField("OpenAI API Key", text: $appState.apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Picker("Profile", selection: $appState.selectedProfileId) {
            ForEach(appState.profiles) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        ForEach(appState.profiles) { profile in
            Menu("  \(profile.name)...") {
                Button("Edit...") {
                    appState.showProfileEditor(profile: profile)
                }
                if profile.id != Profile.general.id {
                    Button("Delete", role: .destructive) {
                        appState.deleteProfile(profile)
                    }
                }
            }
            .font(.caption)
        }
        Button("Add Profile...") {
            appState.showProfileEditor()
        }
        .font(.caption)
    }

    @ViewBuilder
    private var hotkeySection: some View {
        HotkeyRecorderView(appState: appState)
    }

    @ViewBuilder
    private var audioSection: some View {
        Picker("During recording", selection: $appState.duckMode) {
            ForEach(AudioDuckMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        if appState.duckMode == .autoDuck {
            HStack {
                Text("Volume")
                    .font(.caption)
                Slider(value: $appState.duckLevel, in: 0...1)
                Text("\(Int(appState.duckLevel * 100))%")
                    .font(.caption)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if appState.history.isEmpty {
            Text("No transcriptions yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("History")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(appState.history) { entry in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copiedEntryId = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedEntryId == entry.id { copiedEntryId = nil }
                    }
                } label: {
                    HStack {
                        Text(copiedEntryId == entry.id ? "Copied!" : entry.truncatedText)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.relativeTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Clear History") {
                appState.clearHistory()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        Button("Report Bug...") { appState.showFeedback(type: .bug) }
        Button("Request Feature...") { appState.showFeedback(type: .feature) }
    }

    // MARK: - Helpers

    private var statusText: String {
        switch appState.state {
        case .idle: "Ready"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .done: "Done"
        case .error(let msg): msg
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle: .gray
        case .recording: .red
        case .transcribing: .orange
        case .done: .green
        case .error: .red
        }
    }

    // MARK: - Uninstall

    private static func uninstall() {
        let appPaths = [
            "/Applications/Murmur.app",
            NSHomeDirectory() + "/Applications/Murmur.app",
        ]
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            try? FileManager.default.removeItem(atPath: bundlePath)
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        HotkeyConfig.clearSaved()
        PillWindowController.clearPosition()
        Profile.clearSaved()
        for key in ["selectedProvider", "openaiAPIKey", "duckMode", "duckLevel", "transcriptionHistory", "lastUpdateCheck"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Clean up model caches (old location + new persistent location)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let whisperCache = cacheDir?.appendingPathComponent("huggingface") {
            try? FileManager.default.removeItem(at: whisperCache)
        }
        try? FileManager.default.removeItem(at: LocalTranscriber.modelCacheURL())
        NSApplication.shared.terminate(nil)
    }
}
