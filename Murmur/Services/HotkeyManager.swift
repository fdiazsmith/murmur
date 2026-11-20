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

    private var retryTimer: Timer?

    /// Install the event tap. Without Accessibility permission the tap can't
    /// be created; keep trying so the hotkey comes alive as soon as the user
    /// grants it, instead of needing a relaunch.
    func start() {
        guard eventTap == nil else { return }
        if installTap() {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        print("[Murmur] Event tap unavailable — waiting for Accessibility permission")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    var isActive: Bool { eventTap != nil }

    private func installTap() -> Bool {
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
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        Self.tapRef = tap
        print("[Murmur] Global hotkey active (\(Self.config.displayString))")
        return true
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
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
            // The key-up may have been lost while the tap was off.
            if isHotkeyHeld {
                isHotkeyHeld = false
                Task { @MainActor in appState?.stopRecordingAndTranscribe() }
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        if config.isModifierOnly {
            handleModifierOnly(type: type, flags: flags)
        } else {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleKeyCombo(type: type, keyCode: keyCode, flags: flags)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier-only hotkey (e.g. Fn+Shift)

    /// Debounce timer for modifier-only release detection.
    /// macOS generates intermediate flagsChanged events (e.g. Fn fires before Shift joins),
    /// so we wait briefly before treating a mismatch as a real release.
    private static var modifierReleaseWork: DispatchWorkItem?
    /// The recording keeps running through the debounce, so it doubles as
    /// the tail capture — but it is also pure latency, so keep it short. Fn
    /// combos are the ones that flicker, and get longer.
    private static var releaseDebounce: TimeInterval { config.fn ? 0.20 : 0.10 }

    /// Check if all required modifiers are still held (inclusive — ignores extra modifiers)
    private static func hasRequiredModifiers(_ flags: CGEventFlags) -> Bool {
        (!config.control || flags.contains(.maskControl))
            && (!config.shift || flags.contains(.maskShift))
            && (!config.option || flags.contains(.maskAlternate))
            && (!config.command || flags.contains(.maskCommand))
            && (!config.fn || flags.contains(.maskSecondaryFn))
    }

    private static func handleModifierOnly(type: CGEventType, flags: CGEventFlags) {
        guard type == .flagsChanged else { return }

        let exactMatch = config.matchesModifiers(flags)
        let stillHeld = hasRequiredModifiers(flags)

        if exactMatch && !isHotkeyHeld {
            // Exact combo pressed — start recording
            modifierReleaseWork?.cancel()
            modifierReleaseWork = nil
            isHotkeyHeld = true
            Task { @MainActor in appState?.startRecording() }
        } else if stillHeld && isHotkeyHeld {
            // Required modifiers still present (maybe extra flags) — stay recording
            modifierReleaseWork?.cancel()
            modifierReleaseWork = nil
        } else if !stillHeld && isHotkeyHeld {
            // A required modifier was released — debounce then stop
            modifierReleaseWork?.cancel()
            let work = DispatchWorkItem {
                guard isHotkeyHeld else { return }
                isHotkeyHeld = false
                Task { @MainActor in appState?.stopRecordingAndTranscribe(tailCaptured: true) }
            }
            modifierReleaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseDebounce, execute: work)
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
