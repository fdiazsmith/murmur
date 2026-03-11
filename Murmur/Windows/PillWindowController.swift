import AppKit
import SwiftUI

private class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class PillWindowController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func showPill() {
        guard panel == nil else { return }

        let pillView = PillOverlay(appState: appState)
        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 60, height: 60)

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hostingView

        positionPanel(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - 60 - 20
        let y = screenFrame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
