# Upcoming Features

## Audio During Recording

When an app activates the mic on macOS, the system can degrade playback quality — especially on Bluetooth where it switches from AAC (high-quality stereo) to HFP/SCO (telephony codec, ~8kHz mono). This is the "tinny audio on calls" effect. Murmur should handle this gracefully since recordings are short hold-to-speak bursts.

### Two Approaches (user-selectable)

**1. Auto-duck (recommended default)**
- On record start: fade system volume to a configurable level (~20%)
- On record stop: restore previous volume
- Does NOT trigger a device profile switch — playback stays high-quality
- Best for: quick dictation while music/video is playing

**2. Recording mode (opt-in)**
- On record start: switch audio output to a lower sample rate or mute entirely
- Triggers the macOS audio session change (like a video call would)
- On Bluetooth: forces HFP/SCO codec switch (bad quality but lower latency)
- On record stop: revert to previous profile
- Best for: noisy environments where you want minimal audio bleed into mic

### Settings
- Picker: behavior during recording (None / Auto-duck / Recording mode)
- Slider: duck level 0–100% (visible when auto-duck selected)
- Toggle: mute instead of duck (visible when auto-duck selected)

### Implementation Notes
- **Auto-duck**: `CoreAudio` / `AudioObjectSetPropertyData` on default output device volume. Save previous value, restore on stop. Failsafe restore on app quit via `atexit` or `applicationWillTerminate`.
- **Recording mode**: set `AVAudioSession` category to `.playAndRecord` with `.duckOthers` option. On Bluetooth this triggers the SCO/HFP codec switch automatically. Revert to `.playback` on stop.
- Since Murmur recordings are brief (~2-15s), auto-duck is preferable — avoids the ~1s audio glitch from device profile switching.

---

## Transcription History

Browse and copy the last 10 transcriptions from the menu bar dropdown.

### UI
- New section in `MenuBarView` between provider picker and Quit
- List of up to 10 entries, most recent first
- Each entry shows:
  - Truncated text (first ~60 chars)
  - Timestamp (relative: "2m ago", "1h ago")
- Click entry → copies full text to clipboard, shows brief "Copied" confirmation
- "Clear History" button at bottom of list

### Storage
- In-memory array on `AppState`, persisted to `UserDefaults`
- Struct: `TranscriptionEntry { id, text, timestamp }`
- Cap at 10, FIFO eviction

### Implementation Notes
- Add `@Published var history: [TranscriptionEntry]` to `AppState`
- On successful transcription, prepend to history (trim to 10)
- `MenuBarView` renders history list with `.onTapGesture` → `NSPasteboard` copy
