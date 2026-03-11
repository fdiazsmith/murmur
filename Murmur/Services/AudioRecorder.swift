import AVFoundation
import Foundation

final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var tempFileURL: URL?

    private static let sampleRate: Double = 16_000
    private static let channels: AVAudioChannelCount = 1

    private var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.sampleRate,
                      channels: Self.channels,
                      interleaved: false)!
    }

    func start() throws {
        cleanupPreviousTempFile()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempFileURL = url

        let outFormat = targetFormat
        outputFile = try AVAudioFile(forWriting: url,
                                     settings: outFormat.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.outputFile else { return }

            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                         frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil, convertedBuffer.frameLength > 0 else { return }

            do {
                try file.write(from: convertedBuffer)
            } catch {
                // Write failure — silently drop frame
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        return tempFileURL
    }

    private func cleanupPreviousTempFile() {
        guard let url = tempFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
    }

    enum AudioRecorderError: Error, LocalizedError {
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .converterCreationFailed:
                return "Failed to create audio format converter"
            }
        }
    }
}
