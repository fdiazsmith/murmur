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

1. **Hold** the floating pill or the global hotkey (default **Ctrl+Shift+Space**, configurable — modifier-only combos work too)
2. **Speak** — the wordmark in the pill turns into a live waveform, and a bubble above it shows the transcript so far
3. **Release** — the text is pasted at your cursor

Transcription starts while you are still speaking, not when you release:

- at every pause, the audio so far is transcribed speculatively — if you release without saying more, the result is already there (or on its way);
- at long pauses a dictation is split for good, so a five-minute dictation waits no longer on release than a five-second one;
- on release only the unfinished tail is transcribed, and the pieces are stitched together.

Measured on an M4 Pro with large-v3 turbo (`MURMUR_BENCH_AUDIO=… swift test -c release -Xswiftc -enable-testing --filter Benchmark`), release → text:

| | all after release (old) | live, release mid-word | live, release after a beat |
|---|---|---|---|
| 7 s dictation | 0.6 s | 0.6–0.8 s | 0.3 s |
| 42 s dictation | 2.1 s | 1.4 s | 1.0 s |

A profile prompt adds ~7 ms per prompt token to every piece (WhisperKit decodes prompt tokens one step at a time), about 0.6 s for an 80-token prompt. Keep prompts short: a list of terms works as well as prose.

## Features

- **Menu bar app** — no Dock icon, no window clutter
- **Floating pill** — status light + cursive wordmark that becomes the waveform while you speak; shows short messages when something needs your attention ("No speech heard", "Mic is silent", "Copied — press ⌘V")
- **Live preview** — optional transcript bubble while speaking (toggle in the menu)
- **Local transcription** — WhisperKit (Core ML / Neural Engine), large-v3 turbo by default
- **Cloud transcription** — OpenAI Whisper API, bring your own key
- **Profiles** — per-profile prompts for vocabulary and style
- **Paste at cursor** — Cmd+V simulation; your clipboard (all formats) is restored afterwards
- **Screen capture excluded** — pill window won't appear in screenshots or recordings

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

First run downloads the large-v3 turbo model (~630 MB). The first load after an install or OS update can take a couple of minutes while Core ML specializes the model for your chip; the pill says so while it happens.

## Permissions

On first launch, Murmur will request:

1. **Microphone** — system prompt, grant it
2. **Accessibility** — go to System Settings → Privacy & Security → Accessibility, add `Murmur` (from `.build/debug/Murmur`) and your terminal app

## Architecture

```
MurmurApp (@main) + AppDelegate (pill + hotkey start at launch)
  ├── MenuBarExtra (status, profiles, provider, model, hotkey, audio, history)
  ├── PillWindowController (floating NSPanel, screen-capture excluded)
  │     └── PillOverlay (interaction) → PillFace (visuals), TranscriptBubble
  └── AppState (state machine)
        ├── AudioRecorder (AVAudioEngine → 16 kHz mono samples, in memory)
        │     └── AudioLevelMeter (level history for the waveform)
        ├── DictationSession (one dictation, transcribed while recording)
        │     ├── SpeechSegmenter (pause detection → speculate / split)
        │     ├── TranscriptCleaner, TranscriptMerger (tidy + stitch pieces)
        │     └── TranscriptionProvider
        │           ├── LocalTranscriber (WhisperKit, streaming)
        │           └── CloudTranscriber (OpenAI Whisper API, one upload)
        ├── PasteService (NSPasteboard + CGEvent Cmd+V)
        └── HotkeyManager (CGEvent tap; retries until Accessibility is granted)
```

## License

MIT
