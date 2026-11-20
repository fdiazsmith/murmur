import AppKit
import Carbon.HIToolbox
import Foundation

enum PasteService {
    enum Result {
        /// Cmd+V was sent to the frontmost app.
        case pasted
        /// Accessibility isn't granted, so the text was left on the clipboard.
        case copiedOnly
    }

    /// How long the transcript stays on the clipboard before the previous
    /// contents come back. Long enough for a slow app to service the paste.
    private static let restoreDelay: TimeInterval = 0.8

    @MainActor
    static func paste(_ text: String) -> Result {
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted() else {
            // Can't synthesize Cmd+V — leave the text for a manual paste.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        // If an earlier paste hasn't been restored yet, the clipboard holds
        // *our* transcript — keep the snapshot taken before it instead.
        let saved: [NSPasteboardItem]
        if let pending, pending.changeCount == pasteboard.changeCount {
            saved = pending.items
        } else {
            saved = snapshot(of: pasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount
        pending = (saved, ourChange)

        simulateCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // A newer paste owns the restore, or someone copied something
            // else in the meantime — it's theirs now.
            guard pasteboard.changeCount == ourChange else { return }
            pending = nil
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return .pasted
    }

    /// The pre-paste clipboard and the change count of the transcript that
    /// replaced it, until the restore runs.
    @MainActor private static var pending: (items: [NSPasteboardItem], changeCount: Int)?

    /// Copy every item in every flavor (rich text, images, files…), not just
    /// the plain string, so restoring doesn't flatten what the user had.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func simulateCmdV() {
        // A private source: keys the user is still holding (the hotkey's own
        // modifiers) don't leak into the synthesized event.
        let source = CGEventSource(stateID: .privateState)

        let keyDown = CGEvent(keyboardEventSource: source,
                              virtualKey: CGKeyCode(kVK_ANSI_V),
                              keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source,
                            virtualKey: CGKeyCode(kVK_ANSI_V),
                            keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
