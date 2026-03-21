import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Monitors a global hotkey (configurable, default Ctrl+Shift+Space) for hold-to-speak via CGEvent tap.
/// Supports both modifier+key and modifier-only hotkeys.
/// Automatically re-enables the tap if macOS disables it due to timeout.
@MainActor
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Static state accessible from the C callback
    private static var isHotkeyHeld = false
    private static weak var appState: AppState?
    private static var tapRef: CFMachPort?
    private static var config: HotkeyConfig = .default

    init(appState: AppState) {
        Self.appState = appState
        Self.config = HotkeyConfig.load()
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        if Self.isHotkeyHeld {
            Self.isHotkeyHeld = false
            Task { @MainActor in Self.appState?.stopRecordingAndTranscribe() }
        }
        Self.config = newConfig
        newConfig.save()
        print("[Murmur] Hotkey changed to \(newConfig.displayString)")
    }

    var currentConfig: HotkeyConfig { Self.config }

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: HotkeyManager.eventCallback,
            userInfo: nil
        ) else {
            print("[Murmur] Failed to create CGEvent tap — check Accessibility permission")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        Self.tapRef = tap
        print("[Murmur] Global hotkey active (\(Self.config.displayString))")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            Self.tapRef = nil
        }
    }

    // MARK: - Event Callback

    private static let eventCallback: CGEventTapCallBack = { _, type, event, _ -> Unmanaged<CGEvent>? in
        // Re-enable tap if macOS disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tapRef {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[Murmur] Event tap re-enabled after system disable")
            }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags

        if config.isModifierOnly {
            handleModifierOnly(type: type, flags: flags)
        } else {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleKeyCombo(type: type, keyCode: keyCode, flags: flags)
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Modifier-only hotkey (e.g. Fn+Shift)

    private static func handleModifierOnly(type: CGEventType, flags: CGEventFlags) {
        let matchesMods = config.matchesModifiers(flags)

        if type == .flagsChanged {
            if matchesMods && !isHotkeyHeld {
                isHotkeyHeld = true
                Task { @MainActor in appState?.startRecording() }
            } else if !matchesMods && isHotkeyHeld {
                isHotkeyHeld = false
                Task { @MainActor in appState?.stopRecordingAndTranscribe() }
            }
        }
    }

    // MARK: - Key+modifier hotkey (e.g. Ctrl+Shift+Space)

    private static func handleKeyCombo(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let matchesMods = config.matchesModifiers(flags)

        if type == .keyDown && keyCode == Int64(config.keyCode) && matchesMods {
            guard !isHotkeyHeld else { return }
            isHotkeyHeld = true
            Task { @MainActor in appState?.startRecording() }
        } else if type == .keyUp && keyCode == Int64(config.keyCode) && isHotkeyHeld {
            isHotkeyHeld = false
            Task { @MainActor in appState?.stopRecordingAndTranscribe() }
        } else if type == .flagsChanged && isHotkeyHeld && !matchesMods {
            isHotkeyHeld = false
            Task { @MainActor in appState?.stopRecordingAndTranscribe() }
        }
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
