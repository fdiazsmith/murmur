import Foundation

final class CloudTranscriber: TranscriptionProvider {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(fileURL: URL, prompt: String) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(audioData: audioData, prompt: prompt, boundary: boundary)

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

    private func buildMultipartBody(audioData: Data, prompt: String, boundary: String) -> Data {
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
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

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from OpenAI API"
            case .apiError(let statusCode, let message):
                return "OpenAI API error (\(statusCode)): \(message)"
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
