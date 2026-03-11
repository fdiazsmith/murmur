# Murmur — Roadmap

Living document. Completed work removed, only upcoming work lives here.

## Done (v0.0.1)
- [x] Menu bar app skeleton (MenuBarExtra, no Dock icon)
- [x] Floating pill (NSPanel, non-activating, screen-capture excluded)
- [x] Audio recording (AVAudioEngine, 16kHz mono WAV)
- [x] Local transcription (WhisperKit on-device)
- [x] Cloud transcription (OpenAI Whisper API)
- [x] Paste at cursor (NSPasteboard + CGEvent Cmd+V)
- [x] Global hotkey (Ctrl+Shift+Space via CGEvent tap)
- [x] DMG packaging + ad-hoc signing
- [x] Uninstall from menu dropdown

---

## v0.1.0 — Quality of Life

### Transcription History
Browse and copy the last 10 transcriptions from menu dropdown.

- New section in `MenuBarView` between provider picker and Quit
- List of up to 10 entries, most recent first
- Each entry: truncated text (~60 chars) + relative timestamp ("2m ago")
- Click → copy full text to clipboard, brief "Copied" confirmation
- "Clear History" button at bottom
- Storage: `[TranscriptionEntry]` on AppState, persisted to UserDefaults
- Struct: `TranscriptionEntry { id: UUID, text: String, timestamp: Date }`

### Audio During Recording
Handle playback audio gracefully during short hold-to-speak bursts.

**Auto-duck (default):** fade system volume to ~20% on record start, restore on stop. Uses `CoreAudio` / `AudioObjectSetPropertyData`. No device profile switch — playback stays high-quality.

**Recording mode (opt-in):** switch audio session to `.playAndRecord` + `.duckOthers`. On Bluetooth triggers HFP/SCO codec switch. Only for noisy environments.

Settings: picker (None / Auto-duck / Recording mode), duck level slider, mute toggle.

### In-App Feedback (Bug Report / Feature Request)
Let users submit feedback directly from the menu dropdown without leaving the app.

**UX Flow:**
1. Menu dropdown → "Report Bug..." or "Request Feature..."
2. Opens a small floating `NSPanel` (same style as pill — non-activating, stays on top)
3. Panel contains: title field, description text area, submit button, cancel button
4. On submit → opens browser to pre-filled GitHub issue URL
5. Panel dismisses

**Why browser redirect (v1):**
- GitHub API requires auth even on public repos
- No token to leak, no proxy to maintain
- User gets to review before submitting
- Works if repo is public (make repo public for this)

**GitHub URL format:**
```
https://github.com/fdiazsmith/murmur/issues/new?
  labels=bug&
  title={url-encoded title}&
  body={url-encoded description}
```
Labels: `bug` for bug reports, `enhancement` for feature requests. Create these labels in the repo.

**Issue templates** (create in `.github/ISSUE_TEMPLATE/`):
- `bug_report.md` — pre-filled with OS version, Murmur version, steps to reproduce
- `feature_request.md` — pre-filled with description, use case

**Approach: embedded PAT (v1)**
- Fine-grained GitHub PAT scoped to `fdiazsmith/murmur` with Issues read/write only
- Token read from `.env` at build time, XOR-obfuscated in binary (not plain text in `strings`)
- `Services/GitHubIssueService.swift` — POST to `api.github.com/repos/fdiazsmith/murmur/issues`
- Body: `{ "title": "...", "body": "...", "labels": ["bug"] }` or `["enhancement"]`
- No browser redirect, fully in-app submission
- Tradeoff: token extractable from binary, worst case = spam issues (revocable)

**Implementation:**
- `Windows/FeedbackWindowController.swift` — NSPanel, same pattern as PillWindowController
- `Views/FeedbackView.swift` — SwiftUI form (title, description, type picker: Bug/Feature)
- `Services/GitHubIssueService.swift` — API call, token deobfuscation, error handling
- `scripts/bundle.sh` reads `.env` and injects token via build flag or code generation
- Auto-populates issue body with: Murmur version, macOS version, selected provider
- On success: dismiss panel, show brief "Submitted" toast
- On error: show inline error, offer to copy issue text for manual submission

### Auto-Update
Check for new releases on launch, notify user, download and replace.

**How it works:**
1. On app launch (and every 24h while running), `GET https://api.github.com/repos/fdiazsmith/murmur/releases/latest`
2. Compare `tag_name` (e.g. `v0.1.0`) against current `CFBundleShortVersionString`
3. If remote is newer → show banner in menu dropdown: "Update available: v0.1.0"
4. User clicks → downloads DMG asset from the release, opens it
5. User drags new .app to /Applications (standard DMG install)

**Semantic versioning:** tags follow `vMAJOR.MINOR.PATCH`. Compare using Swift's `OperatingSystemVersion` or a simple semver parser.

**Implementation:**
- `Services/UpdateChecker.swift` — fetches latest release, compares versions
- Struct: `GitHubRelease { tagName, htmlURL, assets: [{ name, browserDownloadURL }] }`
- Parse JSON from releases API (public endpoint, no auth needed)
- `@Published var updateAvailable: (version: String, url: URL)?` on AppState
- `MenuBarView` shows update banner when non-nil
- Click downloads DMG via `NSWorkspace.shared.open(url)` (opens in browser/Finder)
- Store `lastUpdateCheck: Date` in UserDefaults, skip if < 24h ago
- No auto-replace (risky without code signing) — user handles install from DMG

**Future (v2):** true auto-update with Sparkle framework (if we get a Developer ID for proper signing).

---

## v0.2.0 — Polish

### Configurable Hotkey
Let users change the global hotkey from menu settings. Store in UserDefaults.

### Model Picker
Let users choose WhisperKit model size (tiny/base/small/medium). Larger = more accurate but slower.

### Onboarding
First-launch flow: request permissions, explain hold-to-speak, test recording.

---

## Backlog (unprioritized)
- Multi-language support (WhisperKit language param)
- Streaming transcription (show partial results while speaking)
- Custom prompt/context for Whisper API (improve accuracy for domain-specific terms)
- Launch at login (LoginItem)
- Menubar icon changes color during recording (like pill does)
- Keyboard shortcut to copy last transcription without re-recording
