import ProsodyCore
@preconcurrency import AVFoundation
import Foundation

extension ProsodyValidation {
    /// Exercise the real AAC writer without opening a microphone. Different
    /// rates in one writer also cover a microphone changing format mid-session.
    static func checkMicrophoneArchiveFormats() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prosody-Microphone-Archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        for bitRate in [96_000, 192_000] {
            let writer = AudioArchiveWriter(
                directoryURL: root.appendingPathComponent("\(bitRate)"), bitRate: bitRate)
            let rates = [24_000.0, 8_000, 16_000, 44_100, 48_000]
            for rate in rates {
                for packetIndex in 0..<10 {
                    let samples = (0..<Int(rate / 10)).map {
                        Float(sin(Double($0) * 2 * .pi * 440 / rate) * 0.2)
                    }
                    try await writer.append(CapturedAudioPacket(source: .microphone,
                        presentationTime: Double(packetIndex) / 10, sampleRate: rate, samples: samples))
                }
            }
            // System + Mic must allow the sources to retain independent rates.
            try await writer.append(CapturedAudioPacket(source: .system,
                presentationTime: 0, sampleRate: 48_000,
                samples: (0..<48_000).map { Float(sin(Double($0) * 0.05) * 0.2) }))
            let urls = try await writer.finish()
            let microphoneURLs = urls.filter {
                $0.deletingLastPathComponent().lastPathComponent == "microphone"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            precondition(urls.count == rates.count + 1 && microphoneURLs.count == rates.count)
            for (url, rate) in zip(microphoneURLs, rates) {
                let file = try AVAudioFile(forReading: url)
                precondition(file.processingFormat.sampleRate == rate)
                precondition(abs(Double(file.length) / rate - 1) < 0.15,
                             "Microphone archive lost duration at \(rate) Hz / \(bitRate) bps")
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength))
                precondition(samples.allSatisfy(\.isFinite) && samples.contains { abs($0) > 0.01 },
                             "Microphone archive did not decode audible PCM")
            }
        }
        print("Microphone archive: PASS (8–48 kHz, both quality settings, mixed sources, rate changes, AAC decoding)")
    }
}
