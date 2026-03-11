# Murmur — macOS Voice-to-Text Menu Bar App

## Context

Build a lightweight macOS menu bar app that records speech via microphone, transcribes it using either **WhisperKit (local, on-device)** or **OpenAI Whisper API (cloud)**, and pastes the result at the current cursor position. Inspired by Wispr Flow but with a local-first, privacy-respecting approach.

## Key Differentiators vs Wispr Flow
- **Local-first** — WhisperKit runs on Apple Silicon, no internet needed. Cloud API optional.
- **Privacy** — no screenshots, no data retention. Cloud mode only sends audio to OpenAI.
- **Lightweight** — minimal resource usage when idle
- **Free/open** — no subscription (cloud mode needs your own API key)

## Architecture

```
MurmurApp (@main)
  ├── MenuBarExtra (mic icon next to clock, dropdown with status/quit)
  ├── PillWindowController (floating NSPanel, screen-capture excluded)
  │     └── PillOverlay (SwiftUI capsule view: hover/click)
  └── AppState (central state machine)
        ├── AudioRecorder (AVAudioEngine → 16kHz mono WAV)
        ├── TranscriptionProvider (protocol)
        │     ├── LocalTranscriber (WhisperKit, "base" model)
        │     └── CloudTranscriber (OpenAI Whisper API)
        └── PasteService (NSPasteboard + CGEvent Cmd+V)
```

## File Structure

```
Murmur/
├── MurmurApp.swift              — @main, MenuBarExtra scene, pill init
├── Info.plist                   — LSUIElement=YES, mic usage description
├── Murmur.entitlements          — no sandbox, audio-input
├── Assets.xcassets/             — app icon, menu bar icon (SF Symbol fallback)
├── Models/
│   └── AppState.swift           — state machine: idle→recording→transcribing→done
├── Views/
│   ├── MenuBarView.swift        — dropdown: status, model info, quit
│   └── PillOverlay.swift        — capsule shape, hover/click, color by state
├── Windows/
│   └── PillWindowController.swift — NSPanel: floating, non-activating, capture-excluded
├── Services/
│   ├── AudioRecorder.swift        — AVAudioEngine, real-time resample to 16kHz mono
│   ├── TranscriptionProvider.swift — protocol: func transcribe(fileURL:) async throws → String
│   ├── LocalTranscriber.swift     — WhisperKit backend (on-device)
│   ├── CloudTranscriber.swift     — OpenAI Whisper API backend (multipart upload)
│   └── PasteService.swift         — clipboard write + CGEvent Cmd+V simulation
└── Utilities/
    └── Permissions.swift        — mic permission request, accessibility check
```

## Interaction Model: Hold-to-Speak

Like Wispr Flow — **hold the pill (or global hotkey) to record, release to transcribe and paste**. This is more natural than click-toggle: hold → speak → release → text appears.

- **Pill**: mouseDown starts recording, mouseUp stops and triggers transcription
- **Global hotkey** (Phase 6): register a system-wide shortcut (e.g. Ctrl+Shift+Space) via `CGEvent` tap or `NSEvent.addGlobalMonitorForEvents` — keyDown starts, keyUp stops

## Implementation Phases

### Phase 1: Project Skeleton
Create Xcode project (macOS App, SwiftUI, deployment target macOS 14.0). Set up:
- `MurmurApp.swift` with `MenuBarExtra` (system mic icon)
- `MenuBarView.swift` with status display + Quit button
- `AppState.swift` with state enum
- `Info.plist`: `LSUIElement = YES`, `NSMicrophoneUsageDescription`
- `Murmur.entitlements`: sandbox OFF, audio-input ON

**Verify:** Build & run → mic icon in menu bar, no Dock icon, dropdown shows quit.

### Phase 2: Floating Pill
- `PillWindowController.swift`: `NSPanel` with `.borderless`, `.nonactivatingPanel`, `.floating` level, `sharingType = .none`, `canJoinAllSpaces`, `stationary`, `ignoresCycle`, transparent background
- `PillOverlay.swift`: capsule with SF Symbol mic icon, changes color on state (gray=idle, red=recording, orange=transcribing), hover effect
- Pill positioned **bottom-right** of screen (above Dock, inset ~20px from right edge)
- Non-activating so interacting doesn't steal focus from current app

**Verify:** Pill floats bottom-right, doesn't appear in screenshots, doesn't steal focus.

### Phase 3: Audio Recording
- `AudioRecorder.swift`: `AVAudioEngine` with input tap, `AVAudioConverter` for 16kHz mono Float32 PCM, writes to temp WAV file
- `Permissions.swift`: `AVCaptureDevice.requestAccess(for: .audio)` + `AXIsProcessTrustedWithOptions` for accessibility
- Wire pill **mouseDown → start recording, mouseUp → stop recording** (hold-to-speak)

**Verify:** Hold pill, speak, release → temp WAV file exists and plays correctly.

### Phase 4: Transcription (Local + Cloud)
- `TranscriptionProvider.swift`: protocol with `func transcribe(fileURL: URL) async throws -> String`
- `LocalTranscriber.swift`: WhisperKit backend — add SPM dep (`https://github.com/argmaxinc/WhisperKit.git`, from `0.9.0`), load "base" model (~140MB, auto-downloaded first run)
- `CloudTranscriber.swift`: OpenAI API backend — multipart POST to `https://api.openai.com/v1/audio/transcriptions` with model `whisper-1`, sends WAV file, returns text. API key stored in `UserDefaults`/Keychain.
- `AppState` holds selected provider, switchable from menu dropdown
- `MenuBarView` gets a picker: Local / Cloud + API key field (shown when Cloud selected)

**Verify:** Hold pill, speak, release → text appears in menu bar status (test both backends).

### Phase 5: Paste at Cursor
- `PasteService.swift`: write text to `NSPasteboard`, simulate Cmd+V via `CGEvent`, restore previous clipboard after 0.5s
- Accessibility permission prompt via `AXIsProcessTrustedWithOptions`
- Wire transcription complete → paste at cursor

**Verify:** Open TextEdit, hold pill, speak, release → text appears in TextEdit.

### Phase 6: Polish & Global Hotkey
- Pulsing animation on pill during recording
- Spinner state during transcription
- Error handling (no mic, model fail, empty transcription)
- **Global hotkey** (e.g. Ctrl+Shift+Space): hold to record from anywhere without needing to reach the pill. Uses `NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp])`

## Dependencies
- **WhisperKit** (`argmaxinc/WhisperKit`) — on-device Whisper, SPM
- No extra deps for cloud — uses Foundation `URLSession` for OpenAI API calls

## Permissions Required
| Permission | Mechanism | Why |
|---|---|---|
| Microphone | Runtime prompt (Info.plist) | Audio recording |
| Accessibility | Manual grant in System Settings | CGEvent paste simulation |
| No Sandbox | Entitlements | Accessibility APIs don't work in sandbox |
| Network | Auto (no sandbox) | Model download (local) or API calls (cloud) |

## Prerequisites
- **Xcode.app** must be installed (not just Command Line Tools) — SwiftUI menu bar apps need the full SDK
- macOS 14.0+ (WhisperKit requirement)
- Apple Silicon recommended (WhisperKit uses CoreML/ANE)

## Verification (End-to-End)
1. Build & run in Xcode (Cmd+R)
2. Menu bar shows mic icon, no Dock icon
3. Floating pill visible at bottom-right, excluded from screenshots
4. Hold pill → turns red (recording) → speak → release → turns orange (transcribing)
5. After ~2-3s, transcribed text appears at cursor in whatever app was focused
6. Menu bar dropdown shows last transcription
