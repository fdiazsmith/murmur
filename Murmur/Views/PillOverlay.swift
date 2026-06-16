import SwiftUI

struct PillOverlay: View {
    @ObservedObject var appState: AppState
    @State private var isHovering = false
    @State private var isPressing = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var isDragging = false
    @State private var mouseStart: CGPoint?
    @State private var windowStart: CGPoint?

    var body: some View {
        VStack(spacing: 4) {
            // Drag handle — visible on hover
            dragHandle
                .opacity(isHovering && !isPressing ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)

            // Pill body
            ZStack {
                Capsule()
                    .fill(backgroundColor)
                    .frame(width: 192, height: 48)
                    .scaleEffect(scaleValue)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                HStack(spacing: 0) {
                    // Profile abbreviation — own hit target, no recording
                    profileSwitcher
                        .frame(width: 52, height: 48)
                        .contentShape(Rectangle())

                    // Recording area — takes the rest
                    ZStack {
                        if appState.state == .transcribing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                                .colorInvert()
                        } else if appState.state == .recording {
                            VStack(spacing: 2) {
                                pillIcon
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 16)
                                    .foregroundStyle(.white)
                                Text(formattedElapsed)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        } else {
                            pillIcon
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 24)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isPressing else { return }
                                isPressing = true
                                appState.startRecording()
                            }
                            .onEnded { _ in
                                isPressing = false
                                appState.stopRecordingAndTranscribe()
                            }
                    )
                }
                .frame(width: 192, height: 48)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: appState.state) { _, newState in
            if newState == .recording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulseScale = 1.15
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pulseScale = 1.0
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.state)
        .frame(width: 192 + 80, height: 48 + 80)
    }

    // MARK: - Profile Switcher

    private var profileSwitcher: some View {
        Menu {
            ForEach(appState.profiles) { profile in
                Button {
                    appState.selectedProfileId = profile.id
                } label: {
                    if profile.id == appState.selectedProfileId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            Text(appState.selectedProfile.abbreviation)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.6))
            .frame(width: 40, height: 5)
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

    private var pillIcon: Image {
        if let url = Bundle.module.url(forResource: "PillIcon@2x", withExtension: "png", subdirectory: "Resources"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "mic.fill")
    }

    private var formattedElapsed: String {
        let t = Int(appState.recordingElapsedTime)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var durationFraction: Double {
        appState.recordingElapsedTime / AudioRecorder.maxDuration
    }

    private var backgroundColor: Color {
        switch appState.state {
        case .idle: return .gray.opacity(0.8)
        case .recording:
            if durationFraction >= 0.95 { return .red }
            if durationFraction >= 0.80 { return .orange }
            return .red
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .red.opacity(0.7)
        }
    }

    private var scaleValue: CGFloat {
        if appState.state == .recording {
            return pulseScale
        }
        return isHovering ? 1.08 : 1.0
    }
}
