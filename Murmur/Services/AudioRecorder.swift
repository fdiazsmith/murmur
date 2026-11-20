import AVFoundation
import CoreAudio
import Foundation

// MARK: - Audio Input Device

struct AudioInputDevice: Identifiable, Hashable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String

    var id: String { uid }

    static func available() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { deviceID in
            var inputAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &streamSize)
            guard streamSize > 0 else { return nil }

            let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
            return AudioInputDevice(deviceID: deviceID, name: name, uid: uid)
        }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of obj: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &value) { ptr in
            _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        return value as String
    }
}

// MARK: - AudioRecorder

/// Captures the microphone as 16 kHz mono float samples, in memory.
///
/// Samples are handed to `onSamples` as they arrive (for live transcription)
/// and levels to `meter` (for the pill waveform); both are called on the
/// audio thread.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    /// UID of the selected input device. nil = system default.
    var selectedDeviceUID: String?

    /// Saved system default to restore after recording.
    private var savedDefaultDevice: AudioDeviceID?

    /// 16kHz mono — Whisper's native format.
    static let sampleRate: Double = 16000
    private static let targetChannels: AVAudioChannelCount = 1

    static let minimumDuration: TimeInterval = 0.3
    static let maxDuration: TimeInterval = 300 // 5 minutes

    /// Current elapsed recording time, updated every 0.5s.
    private(set) var elapsedTime: TimeInterval = 0

    /// Called on each timer tick with the elapsed time.
    var onElapsedTimeUpdate: ((TimeInterval) -> Void)?

    /// Called per tap buffer (audio thread) with the converted samples.
    var onSamples: (([Float]) -> Void)?

    /// Called when recording auto-stops due to max duration.
    var onAutoStop: (() -> Void)?

    /// Live input level history for the waveform.
    let meter = AudioLevelMeter()

    var isRunning: Bool { engine?.isRunning ?? false }

    private var configurationObserver: NSObjectProtocol?

    func start() throws {
        tearDown()

        let newEngine = AVAudioEngine()

        // Set input device via the HAL — AudioUnitSetProperty breaks AVAudioEngine's graph,
        // so we change the system default input instead and restore it on tearDown.
        if let uid = selectedDeviceUID,
           let device = AudioInputDevice.available().first(where: { $0.uid == uid }) {
            savedDefaultDevice = Self.getDefaultInputDevice()
            if Self.setDefaultInputDevice(device.deviceID) {
                print("[Murmur] Using input: \(device.name)")
            }
        }

        meter.reset()
        do {
            try installTap(on: newEngine)
            newEngine.prepare()
            try newEngine.start()
        } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            restoreDefaultDevice()
            throw error
        }
        engine = newEngine
        recordingStartTime = Date()
        elapsedTime = 0

        // The input route can change under a running engine — most often
        // Bluetooth headphones switching to their call profile the moment the
        // mic opens. The engine stops itself when that happens and the tap
        // goes quiet; without this the rest of the dictation is lost.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }

        // Update elapsed time every 0.5s, auto-stop at max duration
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
            self.onElapsedTimeUpdate?(self.elapsedTime)
            if self.elapsedTime >= Self.maxDuration {
                self.onAutoStop?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer

        lastBufferTime.set(Date())
        let watchdog = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.checkCaptureIsAlive()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    /// Tap the input node in its current format, converting to 16 kHz mono.
    private func installTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate,
                                         channels: Self.targetChannels,
                                         interleaved: false)!

        var converter: AVAudioConverter?
        let needsConversion = inputFormat.sampleRate != Self.sampleRate
                              || inputFormat.channelCount != Self.targetChannels
                              || inputFormat.commonFormat != .pcmFormatFloat32
        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioRecorderError.converterCreationFailed
            }
            conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            converter = conv
        }

        var loggedFirstBuffer = false
        // Ask for short buffers (the system may give longer ones): they keep
        // the waveform lively and bound the audio in flight at stop.
        let tapFrames = AVAudioFrameCount(inputFormat.sampleRate * 0.02)
        inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }
            let samples = Self.convert(buffer, with: converter, from: inputFormat, to: outputFormat)
            guard !samples.isEmpty else { return }
            if !loggedFirstBuffer {
                loggedFirstBuffer = true
                print("[Murmur] TAP: first buffer, frames=\(buffer.frameLength), \(Int(inputFormat.sampleRate)) Hz × \(inputFormat.channelCount)ch")
            }
            self.lastBufferTime.set(Date())
            self.meter.push(samples)
            self.onSamples?(samples)
        }
    }

    private func restartAfterConfigurationChange() {
        guard engine != nil, recordingStartTime != nil else { return }
        print("[Murmur] Audio route changed mid-recording — restarting capture")
        rebuildEngine()
    }

    /// Replace the engine with a fresh one on the current route. Restarting
    /// the old engine in place sometimes "succeeds" yet never delivers audio
    /// again while the route is still settling; `checkCaptureIsAlive` calls
    /// this again if the new one stays quiet too.
    private func rebuildEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let newEngine = AVAudioEngine()
        engine = newEngine
        lastBufferTime.set(Date())
        do {
            try installTap(on: newEngine)
            newEngine.prepare()
            try newEngine.start()
        } catch {
            // Leave it to the watchdog to try again shortly.
            print("[Murmur] Could not restart capture: \(error)")
            newEngine.inputNode.removeTap(onBus: 0)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// Buffers normally arrive every 100 ms or faster.
    private static let stallTimeout: TimeInterval = 0.45
    private let lastBufferTime = AtomicDate()
    private var watchdog: Timer?

    /// The tap going quiet while "recording" means the engine died without
    /// telling us (a route change it didn't announce, a device that vanished).
    private func checkCaptureIsAlive() {
        guard recordingStartTime != nil,
              Date().timeIntervalSince(lastBufferTime.value) > Self.stallTimeout else { return }
        print("[Murmur] No audio for \(Self.stallTimeout)s while recording — rebuilding capture")
        rebuildEngine()
    }

    /// Stop capturing. Returns how long the recording ran.
    @discardableResult
    func stop() -> TimeInterval {
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        tearDown()
        return duration
    }

    private func tearDown() {
        durationTimer?.invalidate()
        durationTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        recordingStartTime = nil
        restoreDefaultDevice()
    }

    /// Restore the previous system default input if we changed it.
    private func restoreDefaultDevice() {
        if let saved = savedDefaultDevice {
            Self.setDefaultInputDevice(saved)
            savedDefaultDevice = nil
        }
    }

    /// One tap buffer → 16 kHz mono samples.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> [Float] {
        guard let converter else {
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        // Round capacity up (+ headroom) so the converter never needs an
        // extra input pull just to fit output.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        // Feed this tap buffer exactly once. AVAudioConverter may call the
        // input block multiple times per convert() during resampling; without
        // this guard it re-consumes the same buffer and duplicates audio.
        // .noDataNow (not .endOfStream, which would kill the converter for
        // later tap callbacks) signals no more input this cycle.
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            print("[Murmur] TAP convert error: \(error)")
            return []
        }
        guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    private static func getDefaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else { return nil }
        return deviceID
    }

    @discardableResult
    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = deviceID
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    enum AudioRecorderError: Error, LocalizedError {
        case converterCreationFailed
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .converterCreationFailed:
                return "Failed to create audio format converter"
            case .invalidInputFormat:
                return "Microphone input format is invalid (sample rate or channels are zero)"
            }
        }
    }
}

/// A date readable from the audio thread and the main thread.
final class AtomicDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date.distantPast

    var value: Date { lock.withLock { date } }

    func set(_ newValue: Date) { lock.withLock { date = newValue } }
}
