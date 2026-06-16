import AVFoundation
import Foundation

final class CloudTranscriber: TranscriptionProvider {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(fileURL: URL, prompt: String) async throws -> String {
        // Compress WAV to m4a (AAC) for faster upload — typically 10-20x smaller
        let (uploadData, filename, contentType) = try compressToM4A(from: fileURL)

        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(audioData: uploadData, filename: filename, contentType: contentType, prompt: prompt, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudTranscriberError.apiError(statusCode: httpResponse.statusCode, message: body)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudTranscriberError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compress WAV to m4a (AAC). Falls back to raw WAV on failure.
    private func compressToM4A(from wavURL: URL) throws -> (Data, String, String) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            let inputFile = try AVAudioFile(forReading: wavURL)
            let inputFormat = inputFile.processingFormat
            guard let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            ) else {
                throw CloudTranscriberError.compressionFailed
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVEncoderBitRateKey: 64000,
            ]

            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: outputFormat.commonFormat,
                interleaved: outputFormat.isInterleaved
            )

            let bufferSize: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferSize) else {
                throw CloudTranscriberError.compressionFailed
            }

            while inputFile.framePosition < inputFile.length {
                try inputFile.read(into: buffer)
                try outputFile.write(from: buffer)
            }

            let compressedData = try Data(contentsOf: outputURL)
            let originalSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? UInt64) ?? 0
            print("[Murmur] Cloud: compressed \(originalSize) bytes WAV → \(compressedData.count) bytes m4a")
            return (compressedData, "audio.m4a", "audio/mp4")
        } catch {
            print("[Murmur] Cloud: m4a compression failed (\(error)), using raw WAV")
            let wavData = try Data(contentsOf: wavURL)
            return (wavData, "audio.wav", "audio/wav")
        }
    }

    private func buildMultipartBody(audioData: Data, filename: String, contentType: String, prompt: String, boundary: String) -> Data {
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("whisper-1\r\n")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendString("text\r\n")

        if !prompt.isEmpty {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            body.appendString("\(prompt)\r\n")
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    enum CloudTranscriberError: Error, LocalizedError {
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from OpenAI API"
            case .apiError(let statusCode, let message):
                return "OpenAI API error (\(statusCode)): \(message)"
            case .compressionFailed:
                return "Failed to compress audio for upload"
            }
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
