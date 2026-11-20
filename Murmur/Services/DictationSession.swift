import Foundation

/// One hold-to-speak dictation, transcribed while it is being recorded.
///
/// Audio arrives through `append` as it is captured. With a streaming
/// provider the session doesn't wait for the key to be released:
///
/// - at every pause it transcribes the pending audio speculatively — if the
///   speaker releases without saying more, that result is the answer and
///   nothing is left to do;
/// - at long pauses (and before the pending audio outgrows Whisper's window)
///   it splits the dictation for good, so a five-minute dictation costs the
///   same on release as a five-second one.
///
/// `finish` transcribes only what is still pending and joins the pieces.
/// Pieces run one at a time, in order, each seeing the previous piece's text
/// as context.
final class DictationSession: @unchecked Sendable {
    struct Outcome {
        var text: String
        var audioDuration: Double
        /// Pieces the dictation was transcribed in.
        var pieceCount = 0
        /// Pieces that failed even after retrying; their words are missing.
        var failedPieces = 0
        /// The final piece was already transcribed (or in flight) on release.
        var finishedAhead = false
        /// Nothing was sent to the provider: the mic delivered silence.
        var silent = false
        var error: Error?
    }

    private struct Piece {
        var text = ""
        var error: Error?
        var cancelled = false
    }

    private typealias Job = Task<Piece, Never>

    /// Below this peak RMS the recording is digital silence (muted or dead
    /// mic), not quiet speech.
    static let silentPeakLevel: Float = 0.0005

    /// Below this peak frame RMS (about -48 dBFS) a piece is too faint for
    /// its "speech" to vouch for a phrase Whisper is known to invent.
    static let faintPeakLevel: Float = 0.004

    private let provider: any TranscriptionProvider
    private let profilePrompt: String
    private let streaming: Bool
    private let sampleRate: Double

    private let lock = NSLock()
    private var samples: [Float] = []
    private var segmenter: SpeechSegmenter
    private var committed: [Job] = []
    private var speculation: (cut: Int, job: Job)?
    /// Most recently started job, speculative or not — the next one waits for
    /// it so the provider only ever runs one piece at a time.
    private var lastStarted: Job?
    private var finished = false

    /// Live preview: while the speaker is mid-phrase and the provider is
    /// idle, transcribe the pending audio just to show it. Previews skip the
    /// profile prompt (prompt tokens can't be interrupted, and a preview must
    /// get out of the way the moment the key is released) and never become
    /// part of the result.
    private let livePreview: Bool
    private var preview: Job?
    private var previewEnd = 0
    /// Jobs started and not yet finished.
    private var running = 0
    /// New audio needed before another preview is worth starting.
    static let previewInterval: Double = 1.0

    /// Called (on an arbitrary thread) with the transcript so far whenever
    /// more of it is known.
    private let onPartial: (@Sendable (String) -> Void)?
    private var partialSerial = 0

    init(
        provider: any TranscriptionProvider,
        profilePrompt: String,
        livePreview: Bool = false,
        segmenterConfig: SpeechSegmenter.Config = SpeechSegmenter.Config(),
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.livePreview = livePreview && onPartial != nil
        self.onPartial = onPartial
        self.provider = provider
        self.profilePrompt = profilePrompt
        self.streaming = provider.supportsStreaming
        self.sampleRate = segmenterConfig.sampleRate
        self.segmenter = SpeechSegmenter(config: segmenterConfig)
        samples.reserveCapacity(Int(sampleRate) * 60)
    }

    /// Seconds of quiet at the end of the audio so far.
    var trailingSilence: Double {
        lock.withLock { segmenter.trailingSilence }
    }

    // MARK: - Audio in

    /// Feed captured audio (16 kHz mono). Callable from the audio thread.
    func append(_ chunk: [Float]) {
        lock.withLock {
            guard !finished else { return }
            samples.append(contentsOf: chunk)
            let events = segmenter.append(chunk)
            guard streaming else { return }
            for event in events { handle(event) }
            startPreviewIfUseful()
        }
    }

    /// Caller holds `lock`.
    private func startPreviewIfUseful() {
        guard livePreview, running == 0, speculation == nil else { return }
        let end = samples.count
        let fresh = Double(end - max(previewEnd, committedEnd)) / sampleRate
        guard fresh >= Self.previewInterval,
              segmenter.speechDuration(from: committedEnd, to: end) >= 0.3 else { return }
        previewEnd = end
        preview = makeJob(from: committedEnd, to: end, isPreview: true)
    }

    /// Caller holds `lock`.
    private func handle(_ event: SpeechSegmenter.Event) {
        switch event {
        case let .pause(cut):
            preview?.cancel()
            speculation?.job.cancel()
            speculation = (cut, makeJob(from: committedEnd, to: cut))
        case .speechResumed:
            speculation?.job.cancel()
            speculation = nil
        case let .boundary(cut), let .forcedCut(cut):
            // A preview must not hold up a piece that counts.
            preview?.cancel()
            // The segmenter has already moved its segment start to `cut`, so
            // the piece start is the end of the last committed one.
            if let speculation, speculation.cut == cut {
                committed.append(speculation.job)
            } else {
                speculation?.job.cancel()
                committed.append(makeJob(from: committedEnd, to: cut))
            }
            speculation = nil
            committedEnd = cut
        }
    }

    /// End of the audio covered by `committed` pieces.
    private var committedEnd = 0

    // MARK: - Finish

    /// Stop accepting audio, transcribe what is still pending, and return the
    /// whole dictation.
    func finish() async -> Outcome {
        let (jobs, duration, finishedAhead, silent): ([Job], Double, Bool, Bool) = lock.withLock {
            finished = true
            preview?.cancel()
            let end = samples.count
            let duration = Double(end) / sampleRate
            var finishedAhead = false

            if committed.isEmpty, segmenter.peakLevel < Self.silentPeakLevel {
                speculation?.job.cancel()
                speculation = nil
                return ([], duration, false, true)
            }

            // Audio is only ever left untranscribed when it is plainly quiet
            // next to the speech before it (`isQuiet`) — never on the pause
            // detector's flags alone, which can misread a noisy room or a
            // steady voice as silence.
            if let speculation, segmenter.isQuiet(from: speculation.cut, to: end) {
                // Paused and said nothing since: the speculative piece
                // covers everything.
                committed.append(speculation.job)
                finishedAhead = true
            } else if end > committedEnd {
                speculation?.job.cancel()
                if committed.isEmpty || !segmenter.isQuiet(from: committedEnd, to: end) {
                    committed.append(makeJob(from: committedEnd, to: end))
                }
            }
            speculation = nil
            return (committed, duration, finishedAhead, false)
        }

        var outcome = Outcome(text: "", audioDuration: duration, pieceCount: jobs.count, finishedAhead: finishedAhead, silent: silent)
        var texts: [String] = []
        for job in jobs {
            var piece = await job.value
            // Nothing cancels a committed piece; if one comes back cancelled
            // its words are missing and that must be visible.
            if piece.cancelled, piece.error == nil { piece.error = CancellationError() }
            if let error = piece.error {
                outcome.failedPieces += 1
                if outcome.error == nil { outcome.error = error }
            }
            texts.append(piece.text)
        }
        outcome.text = TranscriptMerger.merge(texts)
        return outcome
    }

    /// Abandon the dictation; in-flight work is cancelled.
    func cancel() {
        lock.withLock {
            finished = true
            preview?.cancel()
            speculation?.job.cancel()
            speculation = nil
            committed.forEach { $0.cancel() }
        }
    }

    // MARK: - Pieces

    /// Caller holds `lock`.
    private func makeJob(from start: Int, to end: Int, isPreview: Bool = false) -> Job {
        let audio = Array(samples[max(0, start)..<min(end, samples.count)])
        // Evidence of speech for the hallucination filter. In a near-silent
        // recording the detector's "loud" is only loud relative to nothing,
        // so it doesn't count.
        let audible = segmenter.peakLevel(from: start, to: end) >= Self.faintPeakLevel
        let speech = audible ? segmenter.speechDuration(from: start, to: end) : 0
        let earlier = committed
        let waitFor = lastStarted
        let provider = provider
        let profilePrompt = isPreview ? "" : profilePrompt
        partialSerial += 1
        let serial = partialSerial
        running += 1
        let job = Job { [weak self] in
            defer { self?.lock.withLock { self?.running -= 1 } }
            _ = await waitFor?.value
            var earlierTexts: [String] = []
            for job in earlier { earlierTexts.append(await job.value.text) }
            guard !Task.isCancelled else { return Piece(cancelled: true) }
            let piece = await Self.transcribe(
                audio, speech: speech, provider: provider, profilePrompt: profilePrompt,
                previousText: earlierTexts.last ?? "", retries: !isPreview
            )
            if !piece.cancelled, !piece.text.isEmpty {
                self?.publishPartial(TranscriptMerger.merge(earlierTexts + [piece.text]), serial: serial)
            }
            return piece
        }
        lastStarted = job
        return job
    }

    /// Jobs finish in the order they were started, but guard anyway: never
    /// let an older transcript replace a newer one, or anything arrive after
    /// the dictation is over.
    private var publishedSerial = 0

    private func publishPartial(_ text: String, serial: Int) {
        let shouldPublish = lock.withLock {
            guard !finished, serial > publishedSerial else { return false }
            publishedSerial = serial
            return true
        }
        if shouldPublish { onPartial?(text) }
    }

    /// Run one piece through the retry ladder: a thrown error retries (it may
    /// be transient); an empty result under a profile prompt retries without
    /// the prompt, which can steer Whisper into silence.
    private static func transcribe(
        _ audio: [Float],
        speech: Double,
        provider: any TranscriptionProvider,
        profilePrompt: String,
        previousText: String,
        retries: Bool = true
    ) async -> Piece {
        let prompts = retries ? TranscriptionRetryLadder.prompts(for: profilePrompt) : [profilePrompt]
        var attempt: Int? = 0
        var lastError: Error?
        while let index = attempt {
            var emptyResult = false
            do {
                let context = TranscriptionContext(prompt: prompts[index], previousText: previousText)
                let raw = try await provider.transcribe(samples: audio, context: context)
                let text = TranscriptCleaner.clean(raw, speechDuration: speech)
                if !text.isEmpty { return Piece(text: text) }
                emptyResult = true
                lastError = nil
            } catch is CancellationError where Task.isCancelled {
                return Piece(cancelled: true)
            } catch {
                if Task.isCancelled { return Piece(cancelled: true) }
                print("[Murmur] Transcription error (attempt \(index)): \(error)")
                lastError = error
            }
            attempt = TranscriptionRetryLadder.nextAttempt(after: index, in: prompts, emptyResult: emptyResult)
            if attempt != nil, lastError != nil {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        return Piece(error: lastError)
    }
}

/// Retry plan for one piece of a dictation:
///
/// - with a profile prompt: prompt, prompt again, then no prompt — a prompt
///   can steer Whisper into empty or garbage output, so the last rung drops it;
/// - without one: a single retry.
///
/// A thrown error retries the same prompt (it may be transient). An empty
/// result does not: decoding is deterministic, so the same prompt on the same
/// audio would just reproduce it — skip to the next different prompt instead.
enum TranscriptionRetryLadder {
    static func prompts(for prompt: String) -> [String] {
        prompt.isEmpty ? ["", ""] : [prompt, prompt, ""]
    }

    /// Index of the next attempt after attempt `index` failed, or nil to give up.
    static func nextAttempt(after index: Int, in prompts: [String], emptyResult: Bool) -> Int? {
        let next = index + 1
        guard next < prompts.count else { return nil }
        guard emptyResult else { return next }
        return prompts[next...].firstIndex(where: { $0 != prompts[index] })
    }
}
