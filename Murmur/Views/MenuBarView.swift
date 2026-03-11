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
            Button("Quit Murmur") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
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
