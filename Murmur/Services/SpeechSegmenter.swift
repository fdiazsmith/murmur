import Foundation

/// Energy-based pause detector for live dictation audio (16 kHz mono).
///
/// It never decides what gets transcribed on its own — it only tells
/// `DictationSession` where the speaker paused, so work can start before the
/// key is released:
///
/// - `.pause`: the speaker has been quiet for a moment. Worth transcribing the
///   pending audio speculatively; if they release now, the answer is ready.
/// - `.speechResumed`: they kept talking after a `.pause` — the speculative
///   result no longer covers the segment.
/// - `.boundary`: the pause is long enough (given how much audio is pending)
///   to split the dictation there for good.
/// - `.forcedCut`: no usable pause before the pending audio got close to
///   Whisper's 30 s window; split at the quietest recent spot.
///
/// Cuts are sample indexes into the recording. Speech/silence is judged
/// against an adaptive noise floor, so it works across mic gains.
struct SpeechSegmenter {
    struct Config {
        var sampleRate: Double = 16_000
        /// Analysis frame, in samples (20 ms).
        var frameLength = 320
        /// Quiet time before a `.pause` is reported.
        var pauseSilence: Double = 0.35
        /// Quiet time that makes a pause a split point, once at least
        /// `boundaryMinDuration` of audio is pending. Short dictations are
        /// never split: one pass over the whole utterance reads best.
        var boundarySilence: Double = 0.7
        var boundaryMinDuration: Double = 6
        /// With a lot pending, a shorter pause is enough.
        var eagerBoundarySilence: Double = 0.45
        var eagerBoundaryMinDuration: Double = 14
        /// Pending audio is force-split at this length.
        var maxSegmentDuration: Double = 24
        /// How far back to look for the quietest spot on a forced cut.
        var forcedCutLookback: Double = 5
        /// Silence kept after the last speech frame when cutting at a pause.
        var cutPadding: Double = 0.2
        /// Speech needed in the pending segment before a pause is reported.
        var minSpeechForPause: Double = 0.2
    }

    enum Event: Equatable {
        case pause(cut: Int)
        case speechResumed
        case boundary(cut: Int)
        case forcedCut(cut: Int)
    }

    let config: Config

    /// Start of the pending (not yet split off) segment.
    private(set) var segmentStart = 0
    /// Loudest frame seen so far (RMS). Near zero means a dead/muted mic.
    private(set) var peakLevel: Float = 0

    private var carry: [Float] = []
    /// Samples consumed as whole frames.
    private var consumed = 0
    private var frameLevels: [Float] = []
    private var frameLoud: [Bool] = []
    private var noiseFloor: Float?

    /// Sample index just past the last loud frame.
    private var lastLoudEnd = 0
    /// Like `lastLoudEnd`, but also updated during a reported pause.
    private var lastLoudFrameEnd = 0
    private var pauseCut: Int?
    private var recentLoud: [Bool] = []

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Queries

    private var frameDuration: Double { Double(config.frameLength) / config.sampleRate }

    private func samples(_ seconds: Double) -> Int { Int(seconds * config.sampleRate) }

    /// Seconds of detected speech in `[start, end)` (sample indexes).
    func speechDuration(from start: Int, to end: Int? = nil) -> Double {
        let first = max(0, start / config.frameLength)
        let last = min(frameLoud.count, (end ?? consumed) / config.frameLength)
        guard first < last else { return 0 }
        return Double(frameLoud[first..<last].lazy.filter { $0 }.count) * frameDuration
    }

    /// Loudest frame (RMS) in `[start, end)`.
    func peakLevel(from start: Int, to end: Int) -> Float {
        let first = max(0, start / config.frameLength)
        let last = min(frameLevels.count, end / config.frameLength)
        guard first < last else { return 0 }
        return frameLevels[first..<last].max() ?? 0
    }

    /// Seconds since the last loud frame, at the end of the audio so far.
    var trailingSilence: Double {
        Double(max(0, consumed - lastLoudFrameEnd)) / config.sampleRate
    }

    /// Whether `[start, end)` is silence *by comparison with the speech
    /// before it* — the only test trusted to leave audio untranscribed.
    ///
    /// The loud/quiet flags follow an adaptive threshold and can go wrong
    /// (a noisy room, a steady voice); this instead asks whether the stretch
    /// stays well below the level speech had earlier in the recording. With
    /// no earlier speech to compare against, nothing counts as quiet.
    func isQuiet(from start: Int, to end: Int) -> Bool {
        let first = max(0, start / config.frameLength)
        let last = min(frameLevels.count, end / config.frameLength)
        guard first < last else { return true }

        let lookback = Int(10 / frameDuration)
        var sum: Float = 0
        var count = 0
        for index in max(0, first - lookback)..<first where frameLoud[index] {
            sum += frameLevels[index]
            count += 1
        }
        guard count > 0 else { return false }
        let ceiling = sum / Float(count) * 0.35
        // One frame may be a click; two is treated as sound worth keeping.
        return frameLevels[first..<last].lazy.filter { $0 > ceiling }.count < 2
    }

    /// True while a reported pause is still running (no speech since).
    var isPaused: Bool { pauseCut != nil }

    // MARK: - Feeding audio

    mutating func append(_ samples: [Float]) -> [Event] {
        carry.append(contentsOf: samples)
        var events: [Event] = []
        var offset = 0
        while carry.count - offset >= config.frameLength {
            let level = Self.rms(carry, offset, config.frameLength)
            offset += config.frameLength
            process(level: level, events: &events)
        }
        if offset > 0 { carry.removeFirst(offset) }
        return events
    }

    private mutating func process(level: Float, events: inout [Event]) {
        let frameStart = consumed
        consumed += config.frameLength
        peakLevel = max(peakLevel, level)

        let loud = level > updateThreshold(with: level)
        if loud { lastLoudFrameEnd = consumed }
        frameLevels.append(level)
        frameLoud.append(loud)
        recentLoud.append(loud)
        if recentLoud.count > 6 { recentLoud.removeFirst() }

        if let cut = pauseCut {
            // In a reported pause. A lone click doesn't end it; sustained
            // sound does.
            if recentLoud.lazy.filter({ $0 }).count >= 3 {
                pauseCut = nil
                lastLoudEnd = consumed
                events.append(.speechResumed)
            } else if isBoundary(cut: cut) {
                pauseCut = nil
                segmentStart = cut
                lastLoudEnd = min(lastLoudEnd, cut)
                events.append(.boundary(cut: cut))
            }
        } else if loud {
            lastLoudEnd = consumed
        } else {
            let quiet = Double(consumed - lastLoudEnd) / config.sampleRate
            let cut = min(consumed, lastLoudEnd + samples(config.cutPadding))
            if quiet >= config.pauseSilence,
               cut > segmentStart,
               speechDuration(from: segmentStart, to: cut) >= config.minSpeechForPause {
                pauseCut = cut
                recentLoud.removeAll()
                events.append(.pause(cut: cut))
            }
        }

        if Double(consumed - segmentStart) / config.sampleRate >= config.maxSegmentDuration {
            let cut = pauseCut ?? quietestPoint(before: frameStart)
            pauseCut = nil
            segmentStart = cut
            events.append(.forcedCut(cut: cut))
        }
    }

    private func isBoundary(cut: Int) -> Bool {
        let pending = Double(cut - segmentStart) / config.sampleRate
        let quiet = Double(consumed - lastLoudEnd) / config.sampleRate
        if pending >= config.eagerBoundaryMinDuration { return quiet >= config.eagerBoundarySilence }
        if pending >= config.boundaryMinDuration { return quiet >= config.boundarySilence }
        return false
    }

    /// Centre of the quietest 100 ms in the lookback window ending at `end`.
    private func quietestPoint(before end: Int) -> Int {
        let window = 5
        let lastFrame = end / config.frameLength
        let earliest = segmentStart / config.frameLength + Int(1.0 / frameDuration)
        let firstFrame = max(earliest, lastFrame - Int(config.forcedCutLookback / frameDuration))
        guard lastFrame - firstFrame > window else { return end }
        var best = firstFrame
        var bestSum = Float.greatestFiniteMagnitude
        var sum = frameLevels[firstFrame..<(firstFrame + window)].reduce(0, +)
        var index = firstFrame
        while true {
            if sum < bestSum { bestSum = sum; best = index }
            let next = index + window
            guard next < lastFrame else { break }
            sum += frameLevels[next] - frameLevels[index]
            index += 1
        }
        return (best + window / 2) * config.frameLength
    }

    // MARK: - Level tracking

    /// Follow the noise floor: drop quickly to quieter frames, creep up
    /// slowly, so the gaps between words keep it anchored during speech.
    private mutating func updateThreshold(with level: Float) -> Float {
        var floor = noiseFloor ?? min(max(level, 0.0002), 0.005)
        if level < floor {
            floor += (level - floor) * 0.2
        } else if level < floor * 2 {
            // Only near-floor frames raise it: sustained speech with no gaps
            // must not drag the floor up until the voice reads as silence.
            floor *= 1.003
        }
        floor = min(max(floor, 0.0002), 0.02)
        noiseFloor = floor
        return max(floor * 3, 0.0015)
    }

    static func rms(_ samples: [Float], _ start: Int, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for index in start..<(start + count) {
                sum += buffer[index] * buffer[index]
            }
        }
        return (sum / Float(count)).squareRoot()
    }
}
