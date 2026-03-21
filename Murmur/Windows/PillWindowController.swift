import AppKit
import SwiftUI

private class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
class PillWindowController {
    private(set) var panel: NSPanel?
    private let appState: AppState

    private let inset: CGFloat = 40
    private let pillWidth: CGFloat = 192
    private let pillHeight: CGFloat = 48

    init(appState: AppState) {
        self.appState = appState
    }

    private var windowWidth: CGFloat { pillWidth + inset * 2 }
    private var windowHeight: CGFloat { pillHeight + inset * 2 }

    func showPill() {
        guard panel == nil else { return }

        let pillView = PillOverlay(appState: appState)
        let hostingView = NSHostingView(rootView: pillView)
        hostingView.sizingOptions = [.intrinsicContentSize]

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hostingView

        if let size = hostingView.intrinsicContentSize as? NSSize,
           size.width > 0, size.height > 0 {
            panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        }

        positionPanel(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        if let saved = Self.loadPosition() {
            panel.setFrameOrigin(saved)
        } else {
            guard let screen = NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - panel.frame.width - 20 + inset
            let y = screenFrame.minY + 80 - inset
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - Position Persistence

    static func savePosition(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: "pillPositionX")
        UserDefaults.standard.set(origin.y, forKey: "pillPositionY")
        UserDefaults.standard.set(true, forKey: "pillPositionCustom")
    }

    static func loadPosition() -> NSPoint? {
        guard UserDefaults.standard.bool(forKey: "pillPositionCustom") else { return nil }
        let x = UserDefaults.standard.double(forKey: "pillPositionX")
        let y = UserDefaults.standard.double(forKey: "pillPositionY")
        return NSPoint(x: x, y: y)
    }

    static func clearPosition() {
        UserDefaults.standard.removeObject(forKey: "pillPositionX")
        UserDefaults.standard.removeObject(forKey: "pillPositionY")
        UserDefaults.standard.removeObject(forKey: "pillPositionCustom")
    }
}
