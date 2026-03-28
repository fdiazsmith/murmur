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
    private var tempFileURL: URL?
    private var recordingStartTime: Date?

    /// UID of the selected input device. nil = system default.
    var selectedDeviceUID: String?

    /// Saved system default to restore after recording.
    private var savedDefaultDevice: AudioDeviceID?

    static let minimumDuration: TimeInterval = 0.3

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

        // Write in native mic format — WhisperKit resamples to 16kHz internally
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempFileURL = url

        let writeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: inputFormat.sampleRate,
                                        channels: inputFormat.channelCount,
                                        interleaved: false)!
        outputFile = try AVAudioFile(forWriting: url,
                                     settings: writeFormat.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        var tapCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.outputFile else {
                if tapCount == 0 { print("[Murmur] TAP: fired but self/file is nil") }
                tapCount += 1
                return
            }
            do {
                try file.write(from: buffer)
                tapCount += 1
                if tapCount == 1 {
                    print("[Murmur] TAP: first buffer written, frames=\(buffer.frameLength)")
                }
            } catch {
                print("[Murmur] TAP write error: \(error)")
            }
        }

        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        recordingStartTime = Date()
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

        // Small delay to ensure AVAudioFile is fully flushed after engine stop
        Thread.sleep(forTimeInterval: 0.05)

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
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        outputFile = nil
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
