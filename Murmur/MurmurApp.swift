import SwiftUI
import AppKit

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: delegate.appState)
        } label: {
            MenuBarLabel(appState: delegate.appState)
        }
    }
}

/// Menu bar icon; switches to a waveform while recording.
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Image(systemName: appState.state == .recording ? "waveform" : "mic.fill")
    }
}

/// Starts the pill and the global hotkey at launch — not from the menu's
/// view lifecycle, which only runs once the menu has been built.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MicCheck.isRequested {
            // Diagnostic run: no pill, no hotkey, no paste.
            Task {
                await MicCheck.run()
                exit(0)
            }
            return
        }
        let pill = PillWindowController(appState: appState)
        pill.showPill()
        appState.pillController = pill

        let hotkey = HotkeyManager(appState: appState)
        appState.hotkeyManager = hotkey

        Task {
            _ = await Permissions.requestMicrophoneAccess()
            _ = Permissions.requestAccessibilityAccess()
            // Retries on its own until Accessibility is granted.
            hotkey.start()
            appState.checkForUpdates()
        }
    }
}
