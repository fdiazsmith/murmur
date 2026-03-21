import AppKit
import Carbon.HIToolbox

@MainActor
class HotkeyRecorderWindowController {
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Hotkey"
        panel.level = .floating
        panel.isMovableByWindowBackground = true

        let captureView = KeyCaptureView { [weak self] config in
            guard let self else { return }
            self.appState.hotkeyConfig = config
            self.dismiss()
        }
        captureView.frame = panel.contentView!.bounds
        captureView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(captureView)

        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(captureView)
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Key Capture NSView

private class KeyCaptureView: NSView {
    var onCapture: ((HotkeyConfig) -> Void)?

    private let label: NSTextField
    private let hintLabel: NSTextField
    private let progressLabel: NSTextField

    private var modifierHoldTimer: DispatchWorkItem?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var didCaptureKey = false

    private static let holdDuration: TimeInterval = 1.0

    init(onCapture: @escaping (HotkeyConfig) -> Void) {
        self.onCapture = onCapture

        label = NSTextField(labelWithString: "Press your new hotkey...")
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center

        hintLabel = NSTextField(labelWithString: "Modifier + key, or hold modifiers for 1s. Esc to cancel.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.alignment = .center
        hintLabel.textColor = .secondaryLabelColor

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.alignment = .center
        progressLabel.textColor = .systemOrange

        super.init(frame: .zero)
        addSubview(label)
        addSubview(hintLabel)
        addSubview(progressLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        label.frame = NSRect(x: 20, y: bounds.height - 55, width: w - 40, height: 30)
        progressLabel.frame = NSRect(x: 20, y: bounds.height - 80, width: w - 40, height: 18)
        hintLabel.frame = NSRect(x: 20, y: bounds.height - 100, width: w - 40, height: 18)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Key events (modifier + key combos)

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelModifierTimer()
            window?.close()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifier = mods.contains(.control) || mods.contains(.shift)
            || mods.contains(.option) || mods.contains(.command)
            || mods.contains(.function)

        guard hasModifier else {
            flashHint()
            return
        }

        // Cancel any modifier-only timer — user pressed a key
        cancelModifierTimer()
        didCaptureKey = true

        let config = HotkeyConfig(
            keyCode: Int(event.keyCode),
            control: mods.contains(.control),
            shift: mods.contains(.shift),
            option: mods.contains(.option),
            command: mods.contains(.command),
            fn: mods.contains(.function),
            keyDisplay: Self.displayName(for: event)
        )

        confirmCapture(config)
    }

    // MARK: - Modifier-only detection (e.g. Fn+Shift)

    override func flagsChanged(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if !relevantModifiers(mods).isEmpty {
            heldModifiers = mods
            label.stringValue = Self.displayModifiers(mods)
            progressLabel.stringValue = "Hold to set as modifier-only..."

            // Restart hold timer
            cancelModifierTimer()
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.heldModifiers == mods, !self.didCaptureKey else { return }
                self.captureModifierOnly(mods)
            }
            modifierHoldTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: timer)
        } else {
            // All modifiers released
            cancelModifierTimer()
            if !didCaptureKey {
                label.stringValue = "Press your new hotkey..."
                progressLabel.stringValue = ""
            }
            heldModifiers = []
        }
    }

    // MARK: - Capture helpers

    private func captureModifierOnly(_ mods: NSEvent.ModifierFlags) {
        let config = HotkeyConfig(
            keyCode: -1,
            control: mods.contains(.control),
            shift: mods.contains(.shift),
            option: mods.contains(.option),
            command: mods.contains(.command),
            fn: mods.contains(.function),
            keyDisplay: ""
        )
        confirmCapture(config)
    }

    private func confirmCapture(_ config: HotkeyConfig) {
        label.stringValue = config.displayString
        progressLabel.stringValue = ""
        hintLabel.stringValue = "Set!"
        hintLabel.textColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.onCapture?(config)
        }
    }

    private func cancelModifierTimer() {
        modifierHoldTimer?.cancel()
        modifierHoldTimer = nil
    }

    private func flashHint() {
        hintLabel.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.hintLabel.textColor = .secondaryLabelColor
        }
    }

    /// Filter to only user-meaningful modifier keys
    private func relevantModifiers(_ mods: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        mods.intersection([.control, .shift, .option, .command, .function])
    }

    // MARK: - Display helpers

    private static func displayModifiers(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.function) { s += "fn " }
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private static func displayName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Pg Up"
        case kVK_PageDown: return "Pg Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key \(event.keyCode)"
        }
    }
}
