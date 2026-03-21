import AppKit
import SwiftUI

@MainActor
class ProfileEditorWindowController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func show(profile: Profile? = nil) {
        dismiss()

        let editorView = ProfileEditorView(appState: appState, profile: profile) { [weak self] in
            self?.dismiss()
        }
        let hostingView = NSHostingView(rootView: editorView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = profile != nil ? "Edit Profile" : "New Profile"
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}
