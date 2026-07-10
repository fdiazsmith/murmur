import SwiftUI
import Combine

struct PillOverlay: View {
    @ObservedObject var appState: AppState
    @State private var isHovering = false
    @State private var isPressing = false
    @State private var isDragging = false
    @State private var mouseStart: CGPoint?
    @State private var windowStart: CGPoint?

    static let pillWidth: CGFloat = 189
    static let pillHeight: CGFloat = 34
    private static let circleSize: CGFloat = 22
    private static let recordRed = Color(red: 0.87, green: 0.36, blue: 0.32)

    var body: some View {
        VStack(spacing: 4) {
            // Drag handle — visible on hover
            dragHandle
                .opacity(isHovering && !isPressing ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)

            // Pill body
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: Self.pillWidth, height: Self.pillHeight)
                    .scaleEffect(scaleValue)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                HStack(spacing: 0) {
                    // Status circle / profile switcher — own hit target, no recording
                    profileCircle

                    // Recording area — takes the rest
                    ZStack {
                        if appState.state == .transcribing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .colorInvert()
                        } else if appState.state == .recording {
                            WaveformView(appState: appState)
                                .frame(height: Self.pillHeight - 9)
                                .padding(.trailing, 14)
                                .transition(.squashToLine)
                        } else {
                            MurmurLogoShape()
                                .fill(.white)
                                .frame(height: 13)
                                .padding(.trailing, 14)
                                .transition(.squashToLine)
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
                .frame(width: Self.pillWidth, height: Self.pillHeight)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeInOut(duration: 0.35), value: appState.state)
        .frame(width: Self.pillWidth + 80, height: Self.pillHeight + 80)
    }

    // MARK: - Status Circle / Profile Switcher

    private var menuEnabled: Bool {
        appState.state != .recording && appState.state != .transcribing
    }

    private var profileCircle: some View {
        // The dot is drawn directly — macOS Menu doesn't reliably render
        // shape labels, so the menu sits on top as an invisible click layer.
        statusDot
            .overlay {
                if menuEnabled {
                    Menu {
                        Picker("Profile", selection: $appState.selectedProfileId) {
                            ForEach(appState.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Color.clear
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
    }

    private var statusDot: some View {
        // Hit target spans the pill's full height, dot centered inside
        ZStack {
            Circle()
                .fill(circleColor)
                .frame(width: Self.circleSize, height: Self.circleSize)
        }
        .frame(width: Self.circleSize + 12, height: Self.pillHeight)
        .contentShape(Rectangle())
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

    private var durationFraction: Double {
        appState.recordingElapsedTime / AudioRecorder.maxDuration
    }

    private var circleColor: Color {
        switch appState.state {
        case .idle: return .white
        case .recording:
            // Warn as the 5-minute cap approaches
            if durationFraction >= 0.80 && durationFraction < 0.95 { return .orange }
            return Self.recordRed
        case .transcribing: return .orange
        case .done: return .green
        case .error: return Self.recordRed.opacity(0.7)
        }
    }

    private var scaleValue: CGFloat {
        isHovering && appState.state != .recording ? 1.02 : 1.0
    }
}

// MARK: - Logo <-> Waveform morph

/// Squashes a view vertically into the pill's midline as it leaves (and grows
/// it back as it enters) — the logo collapses to a flat line, the waveform
/// expands out of it.
private struct SquashToLineModifier: ViewModifier {
    var squashed: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: squashed ? 0.02 : 1)
            .opacity(squashed ? 0 : 1)
    }
}

extension AnyTransition {
    static var squashToLine: AnyTransition {
        .modifier(active: SquashToLineModifier(squashed: true),
                  identity: SquashToLineModifier(squashed: false))
    }
}

// MARK: - Waveform

/// Live scrolling waveform driven by mic level — newest audio enters on the
/// right, the whole squiggle travels left, like the logo caught the sound.
private struct WaveformView: View {
    @ObservedObject var appState: AppState
    @State private var samples: [CGFloat] = Array(repeating: 0, count: 48)
    @State private var phase: CGFloat = 0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let count = samples.count
            let stepX = size.width / CGFloat(count - 1)
            let maxAmp = size.height / 2 - 2
            var points: [CGPoint] = []
            points.reserveCapacity(count)
            for i in 0..<count {
                let x = CGFloat(i) * stepX
                let y = midY + sin(CGFloat(i) * 0.85 - phase) * samples[i] * maxAmp
                points.append(CGPoint(x: x, y: y))
            }
            var path = Path()
            path.move(to: points[0])
            for i in 1..<(count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                                  y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[count - 1])
            context.stroke(path, with: .color(.white),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .onReceive(timer) { _ in
            let level = min(1, CGFloat(appState.audioLevel) * 1.35)
            samples.removeFirst()
            samples.append(max(0.06, level))
            phase += 0.6
        }
    }
}
