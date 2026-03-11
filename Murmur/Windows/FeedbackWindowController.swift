import AppKit
import SwiftUI

@MainActor
class FeedbackWindowController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }

        let feedbackView = FeedbackView(appState: appState) { [weak self] in
            self?.dismiss()
        }
        let hostingView = NSHostingView(rootView: feedbackView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Murmur Feedback"
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
