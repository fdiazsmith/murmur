import AppKit
import AVFoundation
import Foundation

/// `Murmur --mic-check ["sentence"]`: an end-to-end self-test with the real
/// microphone and model, no pill and no paste. The Mac speaks the sentence
/// out of its speakers, Murmur records it the way a dictation would, and the
/// result is printed along with capture and timing numbers.
///
/// Environment: MURMUR_CHECK_PROMPT (profile prompt), MURMUR_CHECK_BEAT
/// (seconds of quiet before "release"), MURMUR_CHECK_MIC / MURMUR_CHECK_SPEAKER
/// (device names), MURMUR_CHECK_SECONDS (record your own voice for that long
/// instead of playing the sentence).
enum MicCheck {
    static var isRequested: Bool { CommandLine.arguments.contains("--mic-check") }

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let index = arguments.firstIndex(of: "--mic-check")!
        let text = arguments.count > index + 1 ? arguments[index + 1]
            : "Okay, so let's refactor the use effect hook in the canvas component, and then run the test suite before we push to main."
        let beat = Double(environment["MURMUR_CHECK_BEAT"] ?? "") ?? 0

        print("[Check] mic authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
        guard await Permissions.requestMicrophoneAccess() else {
            print("[Check] FAILED: microphone access denied")
            return
        }

        let transcriber = LocalTranscriber()
        let loadStart = Date()
        await transcriber.warmup()
        print(String(format: "[Check] model ready in %.1fs", Date().timeIntervalSince(loadStart)))
        guard transcriber.isReady else {
            print("[Check] FAILED: model did not load")
            return
        }

        let partials = Log()
        let session = DictationSession(
            provider: transcriber, profilePrompt: environment["MURMUR_CHECK_PROMPT"] ?? "", livePreview: true
        ) { partials.add($0) }
        let recorder = AudioRecorder()
        // MURMUR_CHECK_MIC / MURMUR_CHECK_SPEAKER: device names, to loop the
        // sentence through a specific mic and speaker (e.g. the built-in ones
        // when headphones are the default).
        if let wanted = environment["MURMUR_CHECK_MIC"] {
            guard let device = AudioInputDevice.available().first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
                print("[Check] FAILED: no input device matching \"\(wanted)\"")
                return
            }
            recorder.selectedDeviceUID = device.uid
        }
        let counter = Counter()
        recorder.onSamples = { samples in
            counter.add(samples)
            session.append(samples)
        }
        let startRequested = Date()
        do {
            try recorder.start()
        } catch {
            print("[Check] FAILED: recorder did not start: \(error)")
            return
        }
        print(String(format: "[Check] recorder.start() took %.0f ms", Date().timeIntervalSince(startRequested) * 1000))
        transcriber.prime()

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        if let seconds = Double(environment["MURMUR_CHECK_SECONDS"] ?? "") {
            // No synthetic speech: you talk for this long.
            print("[Check] speak now — recording for \(seconds)s")
            // Audible cues, since the log isn't visible while this runs.
            NSSound(named: "Tink")?.play()
            try? await Task.sleep(for: .seconds(seconds))
            NSSound(named: "Pop")?.play()
        } else {
            say.arguments = (environment["MURMUR_CHECK_SPEAKER"].map { ["-a", $0] } ?? []) + [text]
            try? say.run()
            say.waitUntilExit()
        }
        if beat > 0 { try? await Task.sleep(for: .seconds(beat)) }

        let released = Date()
        if session.trailingSilence < 0.15 { try? await Task.sleep(for: .milliseconds(120)) }
        let duration = recorder.stop()
        let outcome = await session.finish()
        let latency = Date().timeIntervalSince(released)

        let stats = counter.stats
        print(String(
            format: "[Check] recorded %.2fs wall, %.2fs of samples, %d buffers (avg %.0f ms), first buffer after %.0f ms, peak %.4f, rms %.4f",
            duration, Double(stats.samples) / 16_000, stats.buffers,
            stats.buffers > 0 ? Double(stats.samples) / 16 / Double(stats.buffers) : 0,
            (stats.first?.timeIntervalSince(startRequested) ?? 0) * 1000, stats.peak, stats.rms
        ))
        print(String(
            format: "[Check] release→text %.2fs, pieces %d, failed %d, ahead=%@, silent=%@",
            latency, outcome.pieceCount, outcome.failedPieces,
            outcome.finishedAhead ? "yes" : "no", outcome.silent ? "yes" : "no"
        ))
        print("[Check] said:  \(text)")
        print("[Check] heard: \(outcome.text)")
        print("[Check] partials (\(partials.all.count)): \(partials.all.suffix(3).joined(separator: " | "))")
        let levels = recorder.meter.snapshot().levels
        print(String(format: "[Check] meter: %d levels, max %.2f", levels.count, levels.max() ?? 0))
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ text: String) { lock.withLock { values.append(text) } }
        var all: [String] { lock.withLock { values } }
    }

    private final class Counter: @unchecked Sendable {
        struct Stats {
            var samples = 0
            var buffers = 0
            var peak: Float = 0
            var sumSquares: Double = 0
            var first: Date?
            var rms: Double { samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0 }
        }

        private let lock = NSLock()
        private var value = Stats()

        func add(_ samples: [Float]) {
            lock.withLock {
                if value.first == nil { value.first = Date() }
                value.samples += samples.count
                value.buffers += 1
                for sample in samples {
                    value.peak = max(value.peak, abs(sample))
                    value.sumSquares += Double(sample * sample)
                }
            }
        }

        var stats: Stats { lock.withLock { value } }
    }
}
