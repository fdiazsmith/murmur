import SwiftUI

/// The floating pill: `PillFace` plus everything interactive — hold to
/// record, the profile menu on the orb, the drag handle and the hint chip.
struct PillOverlay: View {
    @ObservedObject var appState: AppState
    @State private var isHovering = false
    @State private var isPressing = false
    @State private var isDragging = false
    @State private var showHint = false
    @State private var pressOwnsRecording = false
    @State private var mouseStart: CGPoint?
    @State private var windowStart: CGPoint?

    static let pillWidth = PillFace.maxWidth
    static let pillHeight = PillFace.height
    /// Transparent margin around the pill for glow, handle and hint.
    static let inset: CGFloat = 40
    /// Room above the pill for the live transcript bubble.
    static let bubbleZone: CGFloat = 64
    static let windowSize = CGSize(width: pillWidth + inset * 2, height: pillHeight + inset * 2 + bubbleZone)

    private var phase: PillPhase { PillPhase(appState.state) }

    var body: some View {
        VStack(spacing: 5) {
            TranscriptBubble(text: appState.state.isBusy ? appState.partialText : "")
                .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(spacing: 5) {
            dragHandle
                .opacity(isHovering && !isPressing && !appState.state.isBusy ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)

            PillFace(
                phase: phase,
                isHovering: isHovering,
                durationFraction: appState.recordingElapsedTime / AudioRecorder.maxDuration,
                meter: appState.audioRecorder.meter
            )
            .overlay(alignment: .leading) { hitAreas }

            hintChip
                .frame(height: 18)
            }
            // Hover belongs to the pill, not the empty bubble area above it.
            .onHover { hovering in
                isHovering = hovering
                if !hovering { showHint = false }
            }
        }
        .padding(.bottom, 12)
        .task(id: isHovering) {
            // Only explain after the pointer has rested on the pill.
            guard isHovering else { return }
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled { showHint = true }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .bottom)
    }

    // MARK: - Interaction

    /// Invisible layer over the face: the orb opens the profile menu, the
    /// rest is the hold-to-speak target.
    private var hitAreas: some View {
        HStack(spacing: 0) {
            profileMenu
                .frame(width: PillFace.lightSlot, height: Self.pillHeight)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressing else { return }
                            isPressing = true
                            // A click during a hotkey dictation must not end it.
                            pressOwnsRecording = !appState.state.isBusy
                            if pressOwnsRecording { appState.startRecording() }
                        }
                        .onEnded { _ in
                            isPressing = false
                            if pressOwnsRecording { appState.stopRecordingAndTranscribe() }
                            pressOwnsRecording = false
                        }
                )
        }
        .frame(width: PillFace.width(for: phase), height: Self.pillHeight)
    }

    @ViewBuilder
    private var profileMenu: some View {
        if appState.state.isBusy {
            Color.clear
        } else {
            // macOS Menu doesn't reliably render shape labels, so the orb is
            // drawn by the face and the menu sits on top as a click layer.
            Menu {
                Picker("Profile", selection: $appState.selectedProfileId) {
                    ForEach(appState.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Edit Profiles…") { appState.showProfileEditor(profile: appState.selectedProfile) }
            } label: {
                Color.clear
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Hint

    private var hintText: String? {
        if appState.selectedProvider == .local, appState.isModelLoading {
            return appState.modelStatus
        }
        if showHint, phase == .idle {
            return "Hold \(appState.hotkeyConfig.displayString) to dictate"
        }
        return nil
    }

    private var hintChip: some View {
        Text(hintText ?? " ")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.62)))
            .opacity(hintText == nil ? 0 : 1)
            .offset(y: hintText == nil ? -3 : 0)
            .animation(.easeOut(duration: 0.18), value: hintText)
            .allowsHitTesting(false)
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.6))
            .frame(width: 32, height: 4)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(windowDragGesture)
            .help("Drag to reposition")
    }

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let window = appState.pillController?.panel else { return }
                let mouse = NSEvent.mouseLocation
                if mouseStart == nil {
                    mouseStart = mouse
                    windowStart = CGPoint(x: window.frame.origin.x, y: window.frame.origin.y)
                    isDragging = true
                }
                let dx = mouse.x - mouseStart!.x
                let dy = mouse.y - mouseStart!.y
                window.setFrameOrigin(NSPoint(x: windowStart!.x + dx, y: windowStart!.y + dy))
            }
            .onEnded { _ in
                isDragging = false
                if let window = appState.pillController?.panel {
                    PillWindowController.savePosition(window.frame.origin)
                }
                mouseStart = nil
                windowStart = nil
            }
    }

}

/// The transcript so far, floating above the pill while you speak — enough
/// to see the words are landing, not a place to read them. Shows the tail.
struct TranscriptBubble: View {
    var text: String

    /// Only the most recent words fit; older ones scroll off the front.
    static let visibleCharacters = 84

    private var tail: String {
        guard text.count > Self.visibleCharacters else { return text }
        let cut = text.suffix(Self.visibleCharacters)
        // Start on a word boundary.
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !text.isEmpty {
                Text(tail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .lineSpacing(1.5)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 262, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(white: 0.09).opacity(0.94))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    )
                    .contentTransition(.opacity)
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: text.isEmpty)
        .animation(.easeOut(duration: 0.18), value: text)
        .allowsHitTesting(false)
    }
}
