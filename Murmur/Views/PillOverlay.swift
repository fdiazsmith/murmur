import SwiftUI

struct PillOverlay: View {
    @ObservedObject var appState: AppState
    @State private var isHovering = false
    @State private var isPressing = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 56, height: 56)
                .scaleEffect(scaleValue)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            if appState.state == .transcribing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
                    .colorInvert()
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Circle())
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
