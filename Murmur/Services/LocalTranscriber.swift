import Foundation
import WhisperKit

final class LocalTranscriber: TranscriptionProvider {
    private let logCollector = WhisperKitLogCollector()

    /// Guards `loadTask` / `loadedKit` / `loadGeneration` / `_modelVariant`:
    /// AppState writes on main while warmup (launch, model switch) and
    /// transcribe resolve the model from other threads.
    private let lock = NSLock()
    /// The in-flight or finished model load. Shared so concurrent callers
    /// await one load instead of each initializing a ~1.6 GB model.
    private var loadTask: Task<WhisperKit, Error>?
    private var loadedKit: WhisperKit?
    /// Bumped by every invalidation. A load tags its progress with the
    /// generation it started in, so a superseded load (cancelled, but Core ML
    /// loads don't stop mid-way) can't overwrite the new model's status.
    private var loadGeneration = 0
    private var _modelVariant: String?

    /// Coverage report from the most recent transcription — inspectable from
    /// the debug menu, and the basis for the Stage-2 incomplete-transcript UI.
    private(set) var lastReport: TranscriptionDiagnostics.Report?

    /// Whisper model variant to use (see `WhisperModelCatalog`).
    var modelVariant: String? {
        get { lock.withLock { _modelVariant } }
        set { lock.withLock { _modelVariant = newValue } }
    }

    /// Called on main thread with (fractionCompleted 0-1, status string).
    var onProgress: (@MainActor (Double, String) -> Void)?

    var isReady: Bool {
        lock.withLock { loadedKit != nil }
    }

    /// Whisper conditions on at most this many prompt tokens. WhisperKit's
    /// decoder context is 224 tokens (not whisper's 448) and the prompt shares
    /// it with the transcription, so WhisperKit itself keeps only the last
    /// 111; trimming here first makes the cut explicit and logged.
    static let maxPromptTokens = Constants.maxTokenContext / 2 - 1

    /// Force re-initialization on next transcription (e.g. after model change).
    /// Cancels an in-flight load of the previous model.
    func invalidate() {
        lock.withLock { invalidateLocked() }
    }

    /// Drop `kit` only if it is still the current model — a model switch may
    /// already have replaced it while a transcription on it was failing.
    private func invalidate(ifCurrent kit: WhisperKit) {
        lock.withLock {
            guard loadedKit === kit else { return }
            invalidateLocked()
        }
    }

    /// Caller holds `lock`.
    private func invalidateLocked() {
        loadTask?.cancel()
        loadTask = nil
        loadedKit = nil
        loadGeneration += 1
    }

    private func isCurrent(generation: Int) -> Bool {
        lock.withLock { generation == loadGeneration }
    }

    let supportsStreaming = true

    /// Previous-text tokens kept as decoder context for a follow-on piece.
    /// Every prompt token costs a decoder step (~7 ms on the Neural Engine),
    /// so this is the tail only — enough for casing and continuity.
    static let maxPreviousTextTokens = 24

    /// One transcription at a time: WhisperKit's decoder state isn't safe to
    /// share, and a cancelled speculative piece may still be inside its
    /// (uncancellable) encoder pass when the next piece is ready.
    private let gate = SerialGate()

    /// Transcribe a wav/audio file (debug menu).
    func transcribe(fileURL: URL, prompt: String) async throws -> String {
        let kit = try await resolveWhisperKit()
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: fileURL.path,
            channelMode: kit.audioInputConfig.channelMode
        )
        return try await transcribe(samples: audio, context: TranscriptionContext(prompt: prompt))
    }

    func transcribe(samples audio: [Float], context: TranscriptionContext) async throws -> String {
        let kit = try await resolveWhisperKit()
        await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()

        do {
            var options = Self.dictationDecodingOptions()
            if let tokenizer = kit.tokenizer {
                let tokens = Self.promptTokens(
                    prompt: context.prompt,
                    previousText: context.previousText,
                    specialTokenBegin: tokenizer.specialTokens.specialTokenBegin,
                    encode: { tokenizer.encode(text: $0) }
                )
                options.promptTokens = tokens.isEmpty ? nil : tokens
            }
            let start = Date()
            logCollector.beginRun()
            let run = try await transcribeChunks(kit: kit, audio: audio, options: options)
            try Task.checkCancellation()
            let chunkTexts = run.results.map(\.text)
            let merged = TranscriptMerger.merge(chunkTexts)
            let audioSeconds = Double(audio.count) / Double(WhisperKit.sampleRate)
            reportCoverage(run: run, audioDuration: audioSeconds, chunkTexts: chunkTexts, mergedText: merged)
            let total = Date().timeIntervalSince(start)
            let timings = run.results.compactMap(\.timings)
            print(String(
                format: "[Murmur][Timing] transcribe: total %.2fs, audio %.1fs, rtf %.2f, chunks %d, prompt %d tok, encode %.2fs, decode loops %d, fallbacks %d",
                total, audioSeconds, audioSeconds > 0 ? total / audioSeconds : 0, run.chunkCount,
                options.promptTokens?.count ?? 0,
                timings.reduce(0) { $0 + $1.encoding },
                Int(timings.reduce(0) { $0 + $1.totalDecodingLoops }),
                Int(timings.reduce(0) { $0 + $1.totalDecodingFallbacks })
            ))
            lock.withLock { lastInference = Date() }
            return merged
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if Self.invalidatesModel(error) {
                print("[Murmur] WhisperKit pipeline error, will reload model next call: \(error)")
                invalidate(ifCurrent: kit)
            } else {
                print("[Murmur] WhisperKit error (model kept loaded): \(error)")
            }
            throw error
        }
    }

    // MARK: - Keeping the model hot

    private var lastInference: Date?

    /// Core ML powers the Neural Engine down after a while idle, and the first
    /// prediction afterwards pays for waking it. Called when recording starts:
    /// run a throwaway pass over silence so the wake-up overlaps the speaker's
    /// first words instead of the wait after release.
    func prime(ifIdleFor idle: TimeInterval = 20) {
        let (kit, last) = lock.withLock { (loadedKit, lastInference) }
        guard let kit else { return }
        if let last, Date().timeIntervalSince(last) < idle { return }
        Task(priority: .userInitiated) {
            await gate.acquire()
            defer { Task { await gate.release() } }
            var options = Self.dictationDecodingOptions()
            options.temperatureFallbackCount = 0
            let silence = [Float](repeating: 0, count: WhisperKit.sampleRate * 2)
            let start = Date()
            // Stop after the first token via the callback. (Don't shorten
            // `sampleLength` instead: WhisperKit traps when it is smaller
            // than its prefilled token count.)
            _ = try? await kit.transcribe(audioArray: silence, decodeOptions: options, callback: { _ in false })
            lock.withLock { lastInference = Date() }
            print(String(format: "[Murmur][Timing] primed model in %.2fs", Date().timeIntervalSince(start)))
        }
    }

    // MARK: - Chunked transcription

    private struct ChunkedRun {
        /// Successful chunk results in time order, segment times absolute.
        let results: [TranscriptionResult]
        let chunkCount: Int
        let recoveredChunkIndices: [Int]
        let failedChunkIndices: [Int]
    }

    /// The same VAD chunking WhisperKit does for `chunkingStrategy: .vad`, run
    /// here instead so a failed chunk comes back as a `Result` (mechanism A)
    /// rather than vanishing inside `updateSeekOffsetsForResults`. Chunks are
    /// at most one 30s window, so each goes through WhisperKit's single-window
    /// path, which seeks with timestamps inside the chunk.
    private func transcribeChunks(kit: WhisperKit, audio: [Float], options: DecodingOptions) async throws -> ChunkedRun {
        let windowSamples = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let chunker = VADAudioChunker(vad: kit.voiceActivityDetector ?? EnergyVAD())
        let chunks = try await chunker.chunkAll(audioArray: audio, maxChunkLength: windowSamples, decodeOptions: options)
        guard !chunks.isEmpty else { throw WhisperError.transcriptionFailed("No audio to transcribe") }

        let cancellation = CancellationFlag()
        let firstPass = await withTaskCancellationHandler {
            await kit.transcribeWithOptions(
            audioArrays: chunks.map(\.audioSamples),
            decodeOptionsArray: Array(repeating: options, count: chunks.count),
            seekOffsets: chunks.map(\.seekOffsetIndex),
            // Returning false stops decoding at the next token. WhisperKit
            // calls this from a detached task, so cancellation has to be
            // carried in by hand.
            callback: { _ in cancellation.isCancelled ? false : nil }
            )
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            let chunk = chunks[index]
            if case let .failure(error) = firstPass[index] {
                print(String(
                    format: "[Murmur][Diag] chunk %d (%.1f–%.1fs) failed: %@ — retrying alone",
                    index, Self.seconds(chunk.seekOffsetIndex), Self.seconds(chunk.seekOffsetIndex + chunk.audioSamples.count),
                    String(describing: error)
                ))
            }
            return try await kit.transcribe(audioArray: chunk.audioSamples, decodeOptions: options)
        }
        if outcome.allFailed {
            throw outcome.firstError ?? WhisperError.transcriptionFailed("All chunks failed")
        }
        if !outcome.recoveredIndices.isEmpty {
            print("[Murmur][Diag] recovered chunks \(outcome.recoveredIndices) on sequential retry")
        }

        // Shift each chunk's segment times by its offset into the recording,
        // exactly as WhisperKit's own chunked path does (results stay in chunk
        // order, which is time order).
        let results = chunker.updateSeekOffsetsForResults(chunkedResults: outcome.results, audioChunks: chunks)
        return ChunkedRun(
            results: results,
            chunkCount: chunks.count,
            recoveredChunkIndices: outcome.recoveredIndices,
            failedChunkIndices: outcome.failedIndices
        )
    }

    private static func seconds(_ sampleIndex: Int) -> Double {
        Double(sampleIndex) / Double(WhisperKit.sampleRate)
    }

    // MARK: - Decoding configuration

    /// Decoding options tuned for push-to-talk dictation, where the user is
    /// almost always speaking and losing a window is worse than a rough one.
    static func dictationDecodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        // Mechanism B: never skip a whole window as "no speech". (WhisperKit
        // 0.16 hardcodes noSpeechProb to 0, so this is defensive today.)
        options.noSpeechThreshold = nil
        // A low-probability first token ends the window's decode immediately;
        // if every fallback temperature trips it, the window comes back empty
        // and the seek still advances a full 30s.
        options.firstTokenLogProbThreshold = nil
        // compressionRatioThreshold (2.4) and logProbThreshold (-1.0) stay:
        // they only trigger the temperature fallback ladder (5 steps), which is
        // whisper's escape from repetition loops — they never drop text.
        //
        // Keep timestamps: the segment spans feed the coverage diagnostics,
        // and a window that fills the token budget re-seeks from its last
        // timestamp instead of jumping a full 30s and losing the rest.
        options.withoutTimestamps = false
        options.skipSpecialTokens = true
        // (suppressBlank is left off: in 0.16 it compares against the prefill
        // cache index and never fires; PromptPrefillEndFilter covers the
        // prompted case where empty windows actually happen.)
        // Chunking is done by `transcribeChunks`.
        options.chunkingStrategy = nil
        return options
    }

    /// Clean prompt tokens: `tokenizer.encode(text:)` wraps the text in special
    /// tokens (<|startoftranscript|>, <|endoftext|>, …) which, forced into the
    /// prompt, can derail decoding into empty or garbage output. Keep only text
    /// tokens, and the tail when over budget — the end of the prompt is what
    /// sits next to the audio.
    static func promptTokens(fromEncoded encoded: [Int], specialTokenBegin: Int, limit: Int = maxPromptTokens) -> [Int] {
        Array(encoded.filter { $0 < specialTokenBegin }.suffix(limit))
    }

    /// The decoder prompt for one piece: the profile prompt, then the tail of
    /// what was just transcribed (closest to the audio, like Whisper's own
    /// previous-segment conditioning). The previous text is capped so the
    /// profile's vocabulary keeps most of the budget.
    static func promptTokens(
        prompt: String,
        previousText: String,
        specialTokenBegin: Int,
        limit: Int = maxPromptTokens,
        previousLimit: Int = maxPreviousTextTokens,
        encode: (String) -> [Int]
    ) -> [Int] {
        func tokens(_ text: String, limit: Int) -> [Int] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, limit > 0 else { return [] }
            // Leading space matches how the text would appear mid-transcript
            // (WhisperKit's CLI does the same).
            return promptTokens(fromEncoded: encode(" " + trimmed), specialTokenBegin: specialTokenBegin, limit: limit)
        }
        let previous = tokens(previousText, limit: min(previousLimit, limit))
        return tokens(prompt, limit: limit - previous.count) + previous
    }

    /// Whether an error means the loaded model / pipeline is broken (reload it)
    /// rather than this one recording failing (keep it — reloading
    /// large-v3 turbo costs seconds and fixes nothing).
    static func invalidatesModel(_ error: Error) -> Bool {
        if let whisperError = error as? WhisperError {
            switch whisperError {
            case .modelsUnavailable, .tokenizerUnavailable, .initializationError,
                 .prefillFailed, .prepareDecoderInputsFailed, .decodingLogitsFailed:
                return true
            default:
                return false
            }
        }
        // MLModel prediction failures surface as raw Core ML NSErrors.
        return (error as NSError).domain == "com.apple.CoreML"
    }

    // MARK: - Diagnostics

    /// Stage-1 gap instrumentation: compare what WhisperKit returned against
    /// the recorded audio (time coverage) and what survived the merge stage
    /// (text accounting), and print a per-run report.
    private func reportCoverage(run: ChunkedRun, audioDuration: Double, chunkTexts: [String], mergedText: String) {
        let results = run.results
        let spans = results.flatMap(\.segments).map { (start: Double($0.start), end: Double($0.end)) }
        let maxNoSpeech = results.flatMap(\.segments).map(\.noSpeechProb).max().map(Double.init)
        // Chunk count and failures come straight from our own chunk loop (the
        // log collector's "Found N VAD chunks" parse only fires on WhisperKit's
        // internal chunked path, which we no longer use). Failures here are
        // the ones that survived the recovery retry.
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: spans,
            audioDuration: audioDuration,
            resultCount: results.count,
            expectedChunkCount: run.chunkCount,
            failedChunkIndices: run.failedChunkIndices,
            maxKeptNoSpeechProb: maxNoSpeech
        )
        lastReport = report
        print(report.consoleSummary)

        // Full text per stage: lets a run's output be diffed chunk -> merged ->
        // (pasted, which AppState logs) to pinpoint where words disappear.
        for (index, result) in results.enumerated() {
            let seek = result.seekTime.map { String(format: "%.1fs", $0) } ?? "?"
            print("[Murmur][Diag] chunk \(index) (seek \(seek)): \(result.text)")
        }
        print(TranscriptionDiagnostics.mergeAccounting(chunkTexts: chunkTexts, mergedText: mergedText).consoleSummary)
        print("[Murmur][Diag] merged: \(mergedText)")
    }

    // MARK: - Model loading

    /// Loads the model (downloading if needed). Safe to call multiple times
    /// and concurrently with `transcribe` — both share one load.
    func warmup() async {
        do {
            _ = try await resolveWhisperKit()
        } catch is CancellationError {
            print("[Murmur] Model load cancelled (model changed)")
        } catch {
            print("[Murmur] Model warmup failed: \(error)")
        }
    }

    private func resolveWhisperKit() async throws -> WhisperKit {
        let task: Task<WhisperKit, Error> = lock.withLock {
            if let loadTask { return loadTask }
            let variant = _modelVariant ?? WhisperModelCatalog.defaultVariant
            let generation = loadGeneration
            let task = Task { try await self.loadWhisperKit(variant: variant, generation: generation) }
            loadTask = task
            return task
        }

        do {
            let kit = try await task.value
            lock.withLock {
                if loadTask == task { loadedKit = kit }
            }
            return kit
        } catch {
            // Let the next call try again instead of replaying this failure.
            lock.withLock {
                if loadTask == task { loadTask = nil }
            }
            throw error
        }
    }

    private func loadWhisperKit(variant: String, generation: Int) async throws -> WhisperKit {
        let start = Date()
        let modelFolder: URL
        if let local = Self.localModelFolder(for: variant) {
            // Already downloaded: load straight from disk. Skips WhisperKit's
            // Hub file listing, which otherwise needs the network on every
            // launch and fails offline even with the model on disk.
            modelFolder = local
        } else {
            reportProgress(0, "Downloading model…", generation: generation)
            modelFolder = try await WhisperKit.download(variant: variant) { [weak self] progress in
                let fraction = progress.fractionCompleted
                self?.reportProgress(fraction, "Downloading model… \(Int(fraction * 100))%", generation: generation)
            }
        }
        try Task.checkCancellation()

        // load/prewarm are run explicitly below so the state callback is
        // attached first — WhisperKit fires those states from inside init
        // otherwise, before any callback can be set.
        // Compute: WhisperKit's defaults are already right on macOS 14 —
        // encoder and decoder on the Neural Engine, mel on GPU.
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(),
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)

        // WhisperKit init forces logLevel to .none when verbose is false —
        // silencing even .error, which is how chunk failures vanish. Re-raise
        // it after init and route lines through the collector, which parses
        // chunk counts/failures and forwards the diagnosis-relevant lines.
        // ("Error transcribing chunk N" logs at .debug level.)
        Logging.shared.logLevel = .debug
        Logging.shared.loggingCallback = { [logCollector] message in
            logCollector.ingest(message)
        }

        kit.modelStateCallback = { [weak self] _, newState in
            let status: String
            switch newState {
            case .downloading: status = "Downloading model…"
            case .downloaded:  status = "Download complete"
            case .loading:     status = "Loading model…"
            case .prewarming:  status = "Preparing model…"
            default:           status = ""
            }
            if !status.isEmpty {
                self?.reportProgress(1.0, status, generation: generation)
            }
        }

        // Prewarm specializes each Core ML model for this chip one at a time
        // (load + unload), capping peak memory for the large model. It only
        // does real work after an OS update evicts Core ML's cache (minutes
        // for large-v3 turbo); otherwise it costs <1s at launch.
        try await kit.prewarmModels()
        try Task.checkCancellation()
        try await kit.loadModels()
        try Task.checkCancellation()

        // Without these, a profile prompt makes every window decode empty and
        // (multilingual models) drops the timestamp rules — see
        // PromptDecodingFilters.swift.
        if let tokenizer = kit.tokenizer {
            var filters: [any LogitsFiltering] = [PromptPrefillEndFilter(specialTokens: tokenizer.specialTokens)]
            if kit.textDecoder.isModelMultilingual {
                filters.append(PromptTimestampRulesFilter(specialTokens: tokenizer.specialTokens))
            }
            kit.textDecoder.logitsFilters = (kit.textDecoder.logitsFilters ?? []) + filters
        }

        print(String(format: "[Murmur] WhisperKit: %@ (%@) loaded in %.1fs", variant, String(describing: kit.modelVariant), Date().timeIntervalSince(start)))
        reportProgress(1.0, "Ready", generation: generation)
        return kit
    }

    /// Forward status for the load started in `generation`, dropping it if a
    /// newer model has been requested since (checked again on delivery, since
    /// the hop to main can land after the switch).
    private func reportProgress(_ fraction: Double, _ status: String, generation: Int) {
        guard let onProgress, isCurrent(generation: generation) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation: generation) else { return }
            onProgress(fraction, status)
        }
    }

    /// The on-disk folder WhisperKit's downloader would produce for `variant`
    /// (Hub layout under ~/Documents/huggingface), if it holds a complete model.
    static func localModelFolder(for variant: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(variant)")
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let complete = required.allSatisfy { name in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path)
        }
        return complete ? folder : nil
    }
}

/// Cancellation state that can be read from any task.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}
