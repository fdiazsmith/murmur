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

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tempFileURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    /// UID of the selected input device. nil = system default.
    var selectedDeviceUID: String?

    /// Saved system default to restore after recording.
    private var savedDefaultDevice: AudioDeviceID?

    /// 16kHz mono — WhisperKit's native format, skips internal resampling.
    private static let targetSampleRate: Double = 16000
    private static let targetChannels: AVAudioChannelCount = 1

    static let minimumDuration: TimeInterval = 0.3
    static let maxDuration: TimeInterval = 300 // 5 minutes

    /// Current elapsed recording time, updated every 0.5s.
    private(set) var elapsedTime: TimeInterval = 0

    /// Called on each timer tick with the elapsed time.
    var onElapsedTimeUpdate: ((TimeInterval) -> Void)?

    /// Called per tap buffer (audio thread) with the normalized mic level (0...1).
    var onLevelUpdate: ((Float) -> Void)?

    /// Called when recording auto-stops due to max duration.
    var onAutoStop: (() -> Void)?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        tearDown()
        cleanupPreviousTempFile()

        let newEngine = AVAudioEngine()

        let inputNode = newEngine.inputNode

        // Set input device via the HAL — AudioUnitSetProperty breaks AVAudioEngine's graph,
        // so we change the system default input instead and restore it on tearDown.
        if let uid = selectedDeviceUID,
           let device = AudioInputDevice.available().first(where: { $0.uid == uid }) {
            savedDefaultDevice = Self.getDefaultInputDevice()
            if Self.setDefaultInputDevice(device.deviceID) {
                print("[Murmur] Using input: \(device.name)")
            }
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        // Write in 16kHz mono — WhisperKit skips resampling, files are ~12x smaller
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempFileURL = url

        let writeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Self.targetSampleRate,
                                        channels: Self.targetChannels,
                                        interleaved: false)!
        outputFile = try AVAudioFile(forWriting: url,
                                     settings: writeFormat.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        // Set up converter from mic format to 16kHz mono
        let needsConversion = inputFormat.sampleRate != Self.targetSampleRate
                              || inputFormat.channelCount != Self.targetChannels
        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: writeFormat) else {
                throw AudioRecorderError.converterCreationFailed
            }
            conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            converter = conv
        }

        var tapCount = 0
        let conv = converter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            if let self, let onLevel = self.onLevelUpdate,
               let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channel[frame]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let db = 20 * log10(max(rms, 1e-7))
                // Map speech range (-50dB quiet ... -8dB loud) to 0...1
                onLevel(min(max((db + 50) / 42, 0), 1))
            }
            guard let self, let file = self.outputFile else {
                if tapCount == 0 { print("[Murmur] TAP: fired but self/file is nil") }
                tapCount += 1
                return
            }
            do {
                if let conv {
                    // Downsample to 16kHz mono. Round capacity up (+ headroom) so the
                    // converter never needs an extra input pull just to fit output.
                    let ratio = Self.targetSampleRate / inputFormat.sampleRate
                    let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: outputFrames) else { return }
                    var error: NSError?
                    // Feed this tap buffer exactly once. AVAudioConverter may call the
                    // input block multiple times per convert() during resampling; without
                    // this guard it re-consumes the same buffer and duplicates audio.
                    // .noDataNow (not .endOfStream, which would kill the converter for
                    // later tap callbacks) signals no more input this cycle.
                    var consumed = false
                    conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error { print("[Murmur] TAP convert error: \(error)"); return }
                    if convertedBuffer.frameLength > 0 {
                        try file.write(from: convertedBuffer)
                    }
                } else {
                    try file.write(from: buffer)
                }
                tapCount += 1
                if tapCount == 1 {
                    print("[Murmur] TAP: first buffer written, frames=\(buffer.frameLength), converting=\(conv != nil)")
                }
            } catch {
                print("[Murmur] TAP write error: \(error)")
            }
        }

        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        recordingStartTime = Date()
        elapsedTime = 0

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
    }

    func stop() -> URL? {
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        tearDown()

        guard duration >= Self.minimumDuration else {
            if duration > 0 {
                print("[Murmur] Recording too short (\(String(format: "%.1f", duration))s), discarding")
            }
            return nil
        }

        guard let url = tempFileURL else { return nil }

        let minFileSize: UInt64 = 5000
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize >= minFileSize else {
            print("[Murmur] Audio file too small, discarding")
            return nil
        }

        print("[Murmur] Recording: \(String(format: "%.1f", duration))s, \(fileSize) bytes")
        return url
    }

    private func tearDown() {
        durationTimer?.invalidate()
        durationTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        outputFile = nil
        converter = nil
        recordingStartTime = nil
        // Restore previous system default input if we changed it
        if let saved = savedDefaultDevice {
            Self.setDefaultInputDevice(saved)
            savedDefaultDevice = nil
        }
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

    private func cleanupPreviousTempFile() {
        guard let url = tempFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
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
