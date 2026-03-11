# Murmur

Local-first voice-to-text for macOS. Hold to speak, release to paste. No subscription, no screenshots, no data retention.

A lightweight alternative to Wispr Flow that runs entirely on-device via WhisperKit (Apple Silicon) — or optionally through the OpenAI Whisper API with your own key.

## Why Murmur over Wispr Flow

| | Murmur | Wispr Flow |
|---|---|---|
| Privacy | No screenshots, no telemetry, audio stays on device | Takes screenshots for context |
| Cost | Free / open source (cloud needs your own API key) | $8–20/mo subscription |
| Offline | Full offline via WhisperKit on Apple Silicon | Requires internet |
| Weight | Minimal — idle menu bar app + floating pill | Heavier runtime |
| Data | Nothing leaves your machine in local mode | Cloud-dependent |

## How it works

1. **Hold** the floating pill (bottom-right of screen) or press **Ctrl+Shift+Space**
2. **Speak** — Murmur records 16kHz mono audio via AVAudioEngine
3. **Release** — audio is transcribed (locally or cloud) and pasted at your cursor

That's it. No click-toggle, no mode switching. Hold to speak, release to paste.

## Features

- **Menu bar app** — mic icon in menu bar, no Dock icon, no window clutter
- **Floating pill** — always-on-top capsule, changes color by state (gray/red/orange/green)
- **Hold-to-speak** — natural press-and-hold interaction on pill or global hotkey
- **Local transcription** — WhisperKit (CoreML/ANE) runs Whisper "base" model on-device
- **Cloud transcription** — OpenAI Whisper API fallback, bring your own key
- **Paste at cursor** — text goes directly into whatever app you're using via Cmd+V simulation
- **Screen capture excluded** — pill window won't appear in screenshots or recordings
- **Global hotkey** — Ctrl+Shift+Space from anywhere, no need to reach the pill

## Requirements

- macOS 14.0+
- Apple Silicon (recommended — WhisperKit uses CoreML/ANE)
- Xcode Command Line Tools or Xcode.app
- Microphone permission
- Accessibility permission (for paste simulation + global hotkey)

## Build & Run

```bash
git clone https://github.com/fdiazsmith/murmur.git
cd murmur
swift build
swift run Murmur
```

First run downloads the WhisperKit "base" model (~140MB). Subsequent launches are instant.

## Permissions

On first launch, Murmur will request:

1. **Microphone** — system prompt, grant it
2. **Accessibility** — go to System Settings → Privacy & Security → Accessibility, add `Murmur` (from `.build/debug/Murmur`) and your terminal app

## Architecture

```
MurmurApp (@main)
  ├── MenuBarExtra (mic icon, dropdown with status/provider/quit)
  ├── PillWindowController (floating NSPanel, screen-capture excluded)
  │     └── PillOverlay (SwiftUI: hold-to-speak, color/animation by state)
  └── AppState (state machine)
        ├── AudioRecorder (AVAudioEngine → 16kHz mono WAV)
        ├── TranscriptionProvider (protocol)
        │     ├── LocalTranscriber (WhisperKit)
        │     └── CloudTranscriber (OpenAI Whisper API)
        ├── PasteService (NSPasteboard + CGEvent Cmd+V)
        └── HotkeyManager (CGEvent tap, Ctrl+Shift+Space)
```

## License

MIT
