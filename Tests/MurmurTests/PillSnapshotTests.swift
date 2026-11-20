import SwiftUI
import XCTest
@testable import Murmur

/// Renders every pill phase to a PNG contact sheet for eyeballing:
///   MURMUR_SNAPSHOT_DIR=/some/dir swift test --filter PillSnapshot
final class PillSnapshotTests: XCTestCase {
    @MainActor
    func testRenderContactSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT_DIR"] else {
            throw XCTSkip("MURMUR_SNAPSHOT_DIR not set")
        }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // ~2.5 s of speech-like levels: syllable bursts with gaps.
        let levels: [Float] = (0..<256).map { index in
            let t = Double(index) * 0.01
            let syllable = max(0, sin(t * 2 * .pi * 3.1))
            let phrase = 0.55 + 0.45 * sin(t * 2 * .pi * 0.7 + 1)
            return Float(min(1, syllable * phrase * 0.95 + 0.04))
        }
        let meter = AudioLevelMeter()
        var envelope: Float = 0
        let smoothed = levels.map { level -> Float in
            envelope = max(level, envelope * AudioLevelMeter.release)
            return envelope
        }
        meter.load(levels: smoothed, startTime: now.addingTimeInterval(-Double(levels.count) * AudioLevelMeter.levelDuration))
        let quiet = AudioLevelMeter()
        quiet.load(levels: [Float](repeating: 0.03, count: 256), startTime: now.addingTimeInterval(-2.56))

        func logo(_ morph: Double, _ meter: AudioLevelMeter) -> AnyView {
            AnyView(LivingLogo(listening: true, thinking: false, meter: meter, frozenAt: now, frozenMorph: morph)
                .frame(width: 119, height: 36)
                .padding(.horizontal, 20)
                .background(Capsule().fill(Color(white: 0.1))))
        }
        let rows: [(String, AnyView)] = [
            ("idle", AnyView(PillFace(phase: .idle, frozenAt: now))),
            ("idle · hover", AnyView(PillFace(phase: .idle, isHovering: true, frozenAt: now))),
            ("morph 0.3 · speaking", logo(0.3, meter)),
            ("morph 0.7 · speaking", logo(0.7, meter)),
            ("morph 1.0 · speaking", logo(1, meter)),
            ("bubble", AnyView(TranscriptBubble(text: "Right now every component calls TanStack Query directly, which makes it hard to share cache keys. What I'd like to do instead is create").frame(width: 262))),
            ("recording · speaking", AnyView(PillFace(phase: .recording, meter: meter, frozenAt: now))),
            ("recording · quiet", AnyView(PillFace(phase: .recording, durationFraction: 0.9, meter: quiet, frozenAt: now))),
            ("release overshoot", logo(-0.35, meter)),
            ("transcribing", AnyView(PillFace(phase: .transcribing, meter: meter, frozenAt: now))),
            ("done", AnyView(PillFace(phase: .done(words: 24), frozenAt: now))),
            ("notice", AnyView(PillFace(phase: .notice("No speech heard"), frozenAt: now))),
            ("error", AnyView(PillFace(phase: .error("Transcription failed"), frozenAt: now))),
        ]

        func sheet(_ background: some ShapeStyle, labelColor: Color) -> some View {
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 18) {
                        Text(rows[index].0)
                            .font(.system(size: 11))
                            .foregroundStyle(labelColor)
                            .frame(width: 130, alignment: .trailing)
                        rows[index].1.frame(width: 280, height: 60)
                    }
                }
            }
            .padding(24)
            .background(Rectangle().fill(background))
        }

        let content = HStack(spacing: 0) {
            sheet(LinearGradient(colors: [Color(red: 0.93, green: 0.92, blue: 0.9), Color(red: 0.8, green: 0.84, blue: 0.9)], startPoint: .top, endPoint: .bottom), labelColor: .black.opacity(0.6))
            sheet(LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.2, green: 0.16, blue: 0.24)], startPoint: .top, endPoint: .bottom), labelColor: .white.opacity(0.6))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("pill-sheet.png")
        try png.write(to: url)
        print("[Snapshot] wrote \(url.path)")
    }
}
