import Foundation

/// 生成并复用一段 1 秒的静音 WAV，供后台保活与画中画保活播放。
enum SilentAudio {
    static func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localapibridge-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds = 1
        let sampleCount = Int(sampleRate) * seconds
        let dataSize = UInt32(sampleCount * Int(bitsPerSample / 8))

        var data = Data()
        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { buffer in
                data.append(contentsOf: buffer)
            }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { buffer in
                data.append(contentsOf: buffer)
            }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8))
        appendUInt16(channels * bitsPerSample / 8)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataSize)
        data.append(Data(count: Int(dataSize)))

        try data.write(to: url, options: .atomic)
        return url
    }
}
