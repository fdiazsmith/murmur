import Foundation

/// Minimal 16-bit PCM WAV encoder for mono float samples.
enum WavWriter {
    static func data(samples: [Float], sampleRate: Int = 16000) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                 // fmt chunk size
        append(UInt16(1))                  // PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))     // byte rate
        append(UInt16(2))                  // block align
        append(UInt16(16))                 // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            append(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }
}
