import SwiftUI

struct HotkeyRecorderView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Menu {
            Button("Change...") {
                appState.showHotkeyRecorder()
            }
            if appState.hotkeyConfig != .default {
                Button("Reset to Default") {
                    appState.hotkeyConfig = .default
                }
            }
        } label: {
            Text("Hotkey: \(appState.hotkeyConfig.displayString)")
        }
    }
}
