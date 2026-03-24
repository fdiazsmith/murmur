import SwiftUI
import AppKit

@main
struct MurmurApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .task {
                    _ = await Permissions.requestMicrophoneAccess()
                    _ = Permissions.requestAccessibilityAccess()
                    showPillIfNeeded()
                    appState.checkForUpdates()
                }
        } label: {
            if let nsImage = Self.loadMenuBarIcon() {
                Image(nsImage: nsImage)
            } else {
                Image(systemName: "mic.fill")
            }
        }
    }

    private static func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: "MenuBarIcon@2x",
            withExtension: "png",
            subdirectory: "Resources"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 22, height: 22)
        return image
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
