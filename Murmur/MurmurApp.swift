import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Murmur", systemImage: "mic.fill") {
            MenuBarView(appState: appState)
                .task {
                    _ = await Permissions.requestMicrophoneAccess()
                    _ = Permissions.requestAccessibilityAccess()
                    showPillIfNeeded()
                }
        }
    }

    @MainActor
    private func showPillIfNeeded() {
        let controller = PillWindowController(appState: appState)
        controller.showPill()
        // Store in appState to retain
        appState.pillController = controller

        let hotkey = HotkeyManager(appState: appState)
        hotkey.start()
        appState.hotkeyManager = hotkey
    }
}
