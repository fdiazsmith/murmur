import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSection
            Divider()
            providerSection
            if !appState.lastTranscription.isEmpty {
                Divider()
                lastTranscriptionSection
            }
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
            Button("Uninstall", role: .destructive) {
                Self.uninstall()
            }
        } message: {
            Text("This will remove Murmur from Applications, clear its settings, and quit.")
        }
    }

    @State private var showUninstallConfirmation = false

    private static func uninstall() {
        // Remove app bundle from /Applications if installed there
        let appPaths = [
            "/Applications/Murmur.app",
            NSHomeDirectory() + "/Applications/Murmur.app",
        ]
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        // Remove the running binary's parent .app bundle if applicable
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            try? FileManager.default.removeItem(atPath: bundlePath)
        }

        // Clear UserDefaults
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        UserDefaults.standard.removeObject(forKey: "selectedProvider")
        UserDefaults.standard.removeObject(forKey: "openaiAPIKey")

        // Remove downloaded WhisperKit models
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let whisperCache = cacheDir?.appendingPathComponent("huggingface") {
            try? FileManager.default.removeItem(at: whisperCache)
        }

        // Quit
        NSApplication.shared.terminate(nil)
    }

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
    private var lastTranscriptionSection: some View {
        Text("Last:")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(appState.lastTranscription)
            .font(.caption)
            .lineLimit(3)
    }

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
}
