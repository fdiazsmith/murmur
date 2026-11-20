import Foundation

/// Rolling history of mic input levels (0...1), written from the audio thread
/// and read by the pill waveform once per display frame. Kept out of
/// `AppState` so level changes don't re-render anything but the waveform.
final class AudioLevelMeter: @unchecked Sendable {
    /// Samples per level (10 ms at 16 kHz).
    static let window = 160
    static let capacity = 256
    /// Per-level decay of the envelope (10 ms steps → ~90 ms half-life).
    static let release: Float = 0.925

    private let lock = NSLock()
    private var levels: [Float] = []
    private var carry: [Float] = []
    private var total = 0
    private var startTime: Date?

    /// Seconds of audio per level.
    static let levelDuration: TimeInterval = Double(window) / 16000

    struct Snapshot {
        /// Most recent levels, oldest first.
        var levels: [Float]
        /// Levels produced since the recording started; `levels.last` is
        /// level number `total - 1`.
        var total: Int
        /// Wall-clock time of level 0, so a reader can place levels on a
        /// timeline and animate smoothly however burstily they arrive.
        var startTime: Date?

        /// Level at `time`, linearly interpolated.
        func level(at time: Date) -> Float {
            guard let startTime, !levels.isEmpty else { return 0 }
            let position = time.timeIntervalSince(startTime) / AudioLevelMeter.levelDuration
            let index = position - Double(total - levels.count)
            guard index > 0 else { return index > -1 ? levels[0] * Float(index + 1) : 0 }
            let lower = Int(index)
            guard lower < levels.count - 1 else { return levels[levels.count - 1] }
            let fraction = Float(index - Double(lower))
            return levels[lower] + (levels[lower + 1] - levels[lower]) * fraction
        }
    }

    func reset() {
        lock.withLock {
            levels.removeAll(keepingCapacity: true)
            carry.removeAll(keepingCapacity: true)
            total = 0
            startTime = nil
        }
    }

    func push(_ samples: [Float]) {
        lock.withLock {
            if startTime == nil {
                startTime = Date().addingTimeInterval(-Double(samples.count) / 16000)
            }
            carry.append(contentsOf: samples)
            var offset = 0
            while carry.count - offset >= Self.window {
                // Envelope follower: jump up with the voice, fall back gently,
                // so the gaps between syllables don't flatten the display.
                let level = max(Self.level(carry, offset, Self.window), (levels.last ?? 0) * Self.release)
                levels.append(level)
                offset += Self.window
                total += 1
            }
            if offset > 0 { carry.removeFirst(offset) }
            if levels.count > Self.capacity { levels.removeFirst(levels.count - Self.capacity) }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(levels: levels, total: total, startTime: startTime) }
    }

    /// Fill with known levels (previews and snapshot tests).
    func load(levels newLevels: [Float], startTime newStart: Date) {
        lock.withLock {
            levels = Array(newLevels.suffix(Self.capacity))
            total = newLevels.count
            startTime = newStart
        }
    }

    /// RMS mapped from the speech range (-50 dB quiet … -8 dB loud) to 0...1.
    static func level(_ samples: [Float], _ start: Int, _ count: Int) -> Float {
        let rms = SpeechSegmenter.rms(samples, start, count)
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 42, 0), 1)
    }
}
