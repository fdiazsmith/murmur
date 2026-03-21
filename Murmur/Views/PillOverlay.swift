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

                if appState.state == .transcribing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .colorInvert()
                } else {
                    pillIcon
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 24)
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Capsule())
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

    private var backgroundColor: Color {
        switch appState.state {
        case .idle: .gray.opacity(0.8)
        case .recording: .red
        case .transcribing: .orange
        case .done: .green
        case .error: .red.opacity(0.7)
        }
    }

    private var scaleValue: CGFloat {
        if appState.state == .recording {
            return pulseScale
        }
        return isHovering ? 1.08 : 1.0
    }
}
