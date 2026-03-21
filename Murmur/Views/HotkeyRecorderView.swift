import SwiftUI

struct HotkeyRecorderView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack {
            Text("Hotkey")
                .font(.caption)
            Spacer()
            Text(appState.hotkeyConfig.displayString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Change") {
                appState.showHotkeyRecorder()
            }
            .font(.caption)
            if appState.hotkeyConfig != .default {
                Button("Reset") {
                    appState.hotkeyConfig = .default
                }
                .font(.caption2)
            }
        }
    }
}
