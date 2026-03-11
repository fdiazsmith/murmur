import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Monitors a global hotkey (Ctrl+Shift+Space) for hold-to-speak via CGEvent tap.
@MainActor
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static var isHotkeyHeld = false
    private static weak var appState: AppState?

    init(appState: AppState) {
        Self.appState = appState
    }

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
        print("[Murmur] Global hotkey active (Ctrl+Shift+Space)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, _ -> Unmanaged<CGEvent>? in
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let hasCtrlShift = flags.contains(.maskControl) && flags.contains(.maskShift)

        if type == .keyDown && keyCode == Int64(kVK_Space) && hasCtrlShift {
            guard !isHotkeyHeld else { return Unmanaged.passRetained(event) }
            isHotkeyHeld = true
            Task { @MainActor in
                appState?.startRecording()
            }
        } else if type == .keyUp && keyCode == Int64(kVK_Space) && isHotkeyHeld {
            isHotkeyHeld = false
            Task { @MainActor in
                appState?.stopRecordingAndTranscribe()
            }
        } else if type == .flagsChanged && isHotkeyHeld && !hasCtrlShift {
            isHotkeyHeld = false
            Task { @MainActor in
                appState?.stopRecordingAndTranscribe()
            }
        }

        return Unmanaged.passRetained(event)
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
