import SwiftUI

/// What the pill is showing. Derived from `AppRecordingState`, but free of
/// app state so the face can be rendered on its own (previews, snapshots).
enum PillPhase: Equatable {
    case idle
    case recording
    case transcribing
    case done(words: Int)
    case notice(String)
    case error(String)

    init(_ state: AppRecordingState) {
        switch state {
        case .idle: self = .idle
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .done(let text): self = .done(words: text.split(whereSeparator: \.isWhitespace).count)
        case .notice(let message): self = .notice(message)
        case .error(let message): self = .error(message)
        }
    }

    var isLive: Bool { self == .recording || self == .transcribing }
}

enum PillPalette {
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let violet = Color(red: 0.56, green: 0.47, blue: 1.0)
    static let cyan = Color(red: 0.36, green: 0.84, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.45, blue: 0.78)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let red = Color(red: 1.0, green: 0.35, blue: 0.33)
}

/// The pill's visuals: a dark capsule holding a status light and the cursive
/// wordmark. While recording, the wordmark's own strokes loosen into a live
/// sound wave driven by the mic; on release they spring back into the logo.
/// No interaction — `PillOverlay` layers that on top.
struct PillFace: View {
    var phase: PillPhase
    var isHovering = false
    /// Fraction of the maximum recording length used so far.
    var durationFraction: Double = 0
    var meter: AudioLevelMeter?
    /// Freeze animations at this instant (snapshot rendering).
    var frozenAt: Date?

    static let height: CGFloat = 36
    static let width: CGFloat = 168
    static let maxWidth: CGFloat = 216
    static let lightSlot: CGFloat = 34

    @State private var shakes: CGFloat = 0

    static func width(for phase: PillPhase) -> CGFloat {
        switch phase {
        case .notice(let message), .error(let message):
            min(maxWidth, max(width, CGFloat(message.count) * 6.6 + 62))
        default:
            width
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            StatusLight(phase: phase, isHovering: isHovering, nearLimit: durationFraction >= 0.8, meter: meter, frozenAt: frozenAt)
                .frame(width: Self.lightSlot, height: Self.height)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 15)
        }
        .frame(width: Self.width(for: phase), height: Self.height)
        .background(PillBackground(phase: phase, isHovering: isHovering, meter: meter, frozenAt: frozenAt))
        .scaleEffect(isHovering && phase == .idle ? 1.04 : 1)
        .modifier(ShakeEffect(shakes: shakes))
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onChange(of: phase) { _, newPhase in
            if case .error = newPhase {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .notice(let message), .error(let message):
            Text(message)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .transition(.blurReplace)
        default:
            // One view across idle → recording → transcribing → done, so the
            // wordmark morphs instead of being swapped out.
            LivingLogo(
                listening: phase == .recording,
                thinking: phase == .transcribing,
                brightness: isHovering || phase != .idle ? 1 : 0.86,
                meter: meter,
                frozenAt: frozenAt
            )
            .transition(.blurReplace)
        }
    }
}

// MARK: - Background & glow

private struct PillBackground: View {
    var phase: PillPhase
    var isHovering: Bool
    var meter: AudioLevelMeter?
    var frozenAt: Date?

    var body: some View {
        ZStack {
            glow
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(white: 0.17), Color(white: 0.07)],
                    startPoint: .top, endPoint: .bottom
                ))
                .opacity(0.94)
                .shadow(color: .black.opacity(0.38), radius: 7, y: 3)
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(isHovering ? 0.42 : 0.26), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            if phase == .transcribing {
                AuroraBorder(frozenAt: frozenAt)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var glow: some View {
        switch phase {
        case .recording:
            VoiceGlow(meter: meter, frozenAt: frozenAt)
                .transition(.opacity)
        case .done:
            PulseRing(color: PillPalette.green, animate: frozenAt == nil)
        case .notice:
            staticGlow(PillPalette.amber, opacity: 0.28)
        case .error:
            staticGlow(PillPalette.red, opacity: 0.45)
        default:
            EmptyView()
        }
    }

    private func staticGlow(_ color: Color, opacity: Double) -> some View {
        Capsule()
            .fill(color)
            .blur(radius: 11)
            .opacity(opacity)
            .transition(.opacity)
    }
}

/// Coral halo that swells with the speaker's voice.
private struct VoiceGlow: View {
    var meter: AudioLevelMeter?
    var frozenAt: Date?

    var body: some View {
        TimelineView(.animation(paused: frozenAt != nil)) { timeline in
            let now = frozenAt ?? timeline.date
            let level = CGFloat(meter?.snapshot().level(at: now.addingTimeInterval(-LivingLogo.latency)) ?? 0)
            Capsule()
                .fill(PillPalette.coral)
                .blur(radius: 9 + 7 * level)
                .opacity(0.22 + 0.5 * level)
                .scaleEffect(x: 1 + 0.03 * level, y: 1 + 0.22 * level)
        }
    }
}

/// A band of colour travelling around the pill's edge while it thinks.
private struct AuroraBorder: View {
    var frozenAt: Date?

    var body: some View {
        TimelineView(.animation(paused: frozenAt != nil)) { timeline in
            let seconds = (frozenAt ?? timeline.date).timeIntervalSinceReferenceDate
            let gradient = AngularGradient(
                colors: [PillPalette.violet, PillPalette.cyan, PillPalette.pink.opacity(0.9), PillPalette.violet.opacity(0), PillPalette.violet],
                center: .center,
                angle: .degrees(seconds.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
            )
            ZStack {
                Capsule().strokeBorder(gradient, lineWidth: 3).blur(radius: 6).opacity(0.75)
                Capsule().strokeBorder(gradient, lineWidth: 1.25)
            }
        }
    }
}

/// One ring that expands off the pill and fades — the "done" flourish.
private struct PulseRing: View {
    var color: Color
    var animate: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            Capsule().fill(color).blur(radius: 10).opacity(expanded ? 0.16 : 0.5)
            Capsule()
                .strokeBorder(color, lineWidth: 1.5)
                .scaleEffect(x: expanded ? 1.16 : 1, y: expanded ? 1.7 : 1)
                .opacity(expanded ? 0 : 0.9)
        }
        .onAppear {
            guard animate else { return }
            withAnimation(.easeOut(duration: 0.7)) { expanded = true }
        }
    }
}

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(shakes * .pi * 6), y: 0))
    }
}

// MARK: - Status light

/// The dot at the pill's leading edge: a recording light while listening,
/// otherwise a quiet marker (and the profile menu's click target).
private struct StatusLight: View {
    var phase: PillPhase
    var isHovering: Bool
    var nearLimit: Bool
    var meter: AudioLevelMeter?
    var frozenAt: Date?

    @State private var spin = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                Circle()
                    .fill(.white.opacity(isHovering ? 0.16 : 0))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(.white.opacity(isHovering ? 1 : 0.9))
                    .frame(width: 9, height: 9)
            case .recording:
                RecordingLight(color: nearLimit ? PillPalette.amber : PillPalette.coral, meter: meter, frozenAt: frozenAt)
            case .transcribing:
                Circle()
                    .trim(from: 0.08, to: 0.78)
                    .stroke(
                        AngularGradient(colors: [PillPalette.violet.opacity(0), PillPalette.cyan], center: .center,
                                        startAngle: .degrees(20), endAngle: .degrees(290)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        guard frozenAt == nil else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
                    .onDisappear { spin = false }
            case .done:
                Circle().fill(PillPalette.green).frame(width: 16, height: 16)
                CheckmarkShape()
                    .trim(from: 0, to: drawn || frozenAt != nil ? 1 : 0)
                    .stroke(Color.black.opacity(0.78), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .frame(width: 7.5, height: 7)
                    .onAppear { withAnimation(.easeOut(duration: 0.28).delay(0.08)) { drawn = true } }
                    .onDisappear { drawn = false }
            case .notice:
                Circle().fill(PillPalette.amber).frame(width: 16, height: 16)
                glyph("exclamationmark")
            case .error:
                Circle().fill(PillPalette.red).frame(width: 16, height: 16)
                glyph("xmark")
            }
        }
        .padding(.leading, 3)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundStyle(.black.opacity(0.78))
    }
}

/// The red light: a steady core with a halo that breathes with the voice.
private struct RecordingLight: View {
    var color: Color
    var meter: AudioLevelMeter?
    var frozenAt: Date?

    var body: some View {
        TimelineView(.animation(paused: frozenAt != nil)) { timeline in
            let now = frozenAt ?? timeline.date
            let level = CGFloat(meter?.snapshot().level(at: now.addingTimeInterval(-LivingLogo.latency)) ?? 0)
            ZStack {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: 13 + 9 * level, height: 13 + 9 * level)
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color, radius: 3 + 3 * level)
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.14))
        return path
    }
}

// MARK: - Living logo

/// The cursive "murmur" wordmark as a live thing.
///
/// At rest it is the logo. While listening, its strokes are pulled toward the
/// pill's midline and displaced by a wave whose height follows the mic — sound
/// enters at the right and travels left, so the word itself becomes the
/// waveform. On release the displacement springs back (with a little
/// overshoot) and the letters snap into place. While the transcription
/// finishes, a soft highlight sweeps across the settled wordmark.
struct LivingLogo: View {
    var listening: Bool
    var thinking: Bool
    var brightness: Double = 1
    var meter: AudioLevelMeter?
    var frozenAt: Date?
    /// Fix the logo→wave morph amount (snapshot rendering).
    var frozenMorph: Double?

    /// Display lag behind the mic. Levels arrive in bursts; reading slightly
    /// in the past means there is always data to interpolate.
    static let latency: TimeInterval = 0.07
    /// Seconds of sound visible across the wordmark.
    private static let span: TimeInterval = 0.55
    private static let logoHeight: CGFloat = 12.5

    @State private var listeningSince: Date?
    @State private var releasedAt: Date?

    var body: some View {
        TimelineView(.animation(paused: frozenAt != nil || !(listening || thinking || isSettling))) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: frozenAt ?? timeline.date)
            }
        }
        .onAppear {
            // Created mid-recording (e.g. replacing a notice): onChange won't
            // fire for the initial value.
            if listening, listeningSince == nil { listeningSince = Date() }
        }
        .onChange(of: listening) { _, isListening in
            if isListening {
                listeningSince = Date()
                releasedAt = nil
            } else {
                releasedAt = Date()
                listeningSince = nil
            }
        }
        .task(id: releasedAt) {
            // Keep animating until the spring-back has settled, then go idle
            // (a paused timeline costs nothing).
            guard releasedAt != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled, !listening { releasedAt = nil }
        }
    }

    private var isSettling: Bool { releasedAt != nil }

    /// 0 = logo, 1 = wave. Eases in on press; on release rings back through
    /// zero like a plucked string.
    private func morph(at now: Date) -> Double {
        if let frozenMorph { return frozenMorph }
        if listening {
            let elapsed = now.timeIntervalSince(listeningSince ?? now)
            let progress = min(1, max(0, elapsed / 0.28))
            return 1 - pow(1 - progress, 3)
        }
        // Between `listening` flipping and onChange recording the release
        // there can be a frame; hold the wave rather than flash the logo.
        guard let releasedAt else { return listeningSince != nil ? 1 : 0 }
        let elapsed = max(0, now.timeIntervalSince(releasedAt))
        return exp(-7.5 * elapsed) * cos(21 * elapsed)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let box = MurmurLogoShape.viewBox
        let scale = min(size.width / box.width, Self.logoHeight / box.height)
        let logoWidth = box.width * scale
        let originX = (size.width - logoWidth) / 2
        let midY = size.height / 2
        let originY = midY - box.height * scale / 2

        let morph = morph(at: now)
        let seconds = now.timeIntervalSinceReferenceDate
        let reach = size.height / 2 - 2.5

        // Voice level along the wordmark: newest sound at the right edge.
        let columns = 48
        var levels = [Double](repeating: 0, count: columns + 1)
        if abs(morph) > 0.001, let snapshot = meter?.snapshot() {
            for column in 0...columns {
                let age = (1 - Double(column) / Double(columns)) * Self.span
                levels[column] = Double(snapshot.level(at: now.addingTimeInterval(-Self.latency - age)))
            }
        }

        func transform(_ point: CGPoint) -> CGPoint {
            let x = originX + point.x * scale
            let y = originY + point.y * scale
            guard abs(morph) > 0.001 else { return CGPoint(x: x, y: y) }

            let u = min(1, max(0, Double(point.x / box.width)))
            let position = u * Double(columns)
            let lower = min(columns - 1, Int(position))
            let fraction = position - Double(lower)
            let level = levels[lower] + (levels[lower + 1] - levels[lower]) * fraction
            let loudness = min(1, pow(level, 0.8) * 1.2)

            // Letters flatten toward the midline as the voice takes over…
            let squash = 1 - morph * (0.5 + 0.47 * loudness)
            // …and ride a travelling wave whose height is the voice.
            let wave = 0.68 * sin(u * 2 * .pi * 3.1 + seconds * 8.5)
                + 0.32 * sin(u * 2 * .pi * 7.3 - seconds * 12.5)
            let taper = pow(sin(.pi * min(1, max(0, u * 0.94 + 0.03))), 0.55)
            let lift = morph * (0.1 + 1.15 * loudness) * wave * taper * Double(reach)
            return CGPoint(x: x, y: midY + (y - midY) * squash + lift)
        }

        var path = Path()
        for element in MurmurLogoShape.elements {
            switch element {
            case let .move(to): path.move(to: transform(to))
            case let .line(to): path.addLine(to: transform(to))
            case let .curve(to, control1, control2):
                path.addCurve(to: transform(to), control1: transform(control1), control2: transform(control2))
            case .close: path.closeSubpath()
            }
        }

        if thinking {
            // A highlight sweeping left → right across a dimmed wordmark.
            let sweep = (frozenAt != nil ? 0.45 : (seconds.truncatingRemainder(dividingBy: 1.5) / 1.5)) * 1.6 - 0.3
            let gradient = Gradient(stops: [
                .init(color: .white.opacity(0.42), location: max(0, min(1, sweep - 0.28))),
                .init(color: .white, location: max(0, min(1, sweep))),
                .init(color: .white.opacity(0.42), location: max(0, min(1, sweep + 0.28))),
            ])
            context.fill(path, with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: originX, y: midY),
                endPoint: CGPoint(x: originX + logoWidth, y: midY)
            ))
        } else {
            context.fill(path, with: .color(.white.opacity(brightness)))
            // Flattened letters get hairline-thin; a stroke keeps the wave's
            // line weight as the logo's weight fades out.
            let weight = min(1, abs(morph)) * 0.9
            if weight > 0.05 {
                context.stroke(path, with: .color(.white.opacity(brightness)),
                               style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
