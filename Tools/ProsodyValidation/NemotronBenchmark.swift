import ProsodyCore
import FluidAudio
import Foundation

extension ProsodyValidation {
    /// Replays fixtures twice at capture cadence against one loaded, local model.
    static func benchmarkNemotron(modelDirectory: URL, paths: [String]) async throws {
        guard modelDirectory.isFileURL, !paths.isEmpty else {
            throw NemotronBenchmarkError("Provide a local Nemotron model directory and at least one audio fixture.")
        }
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: modelDirectory.path))
        guard files.isSuperset(of: ["metadata.json", "tokenizer.json", "encoder.mlmodelc"]),
              files.filter({ $0.hasSuffix(".mlpackage") }).allSatisfy({
                  files.contains(String($0.dropLast(".mlpackage".count)) + ".mlmodelc")
              }) else {
            throw NemotronBenchmarkError("Use a complete compiled Nemotron tier directory (for example, latin/2240ms).")
        }

        let printTranscript = (ProcessInfo.processInfo.environment["PROSODY_BENCHMARK_PRINT_TRANSCRIPT"]
            ?? ProcessInfo.processInfo.environment["CLIPPY_BENCHMARK_PRINT_TRANSCRIPT"]) == "1"
        let manager = StreamingNemotronMultilingualAsrManager()
        let loadStart = ContinuousClock.now
        try await manager.loadModels(from: modelDirectory)
        print(String(format: "Nemotron load and warm-up: %.1f ms", milliseconds(loadStart.duration(to: .now))))
        await manager.setLanguage("en-US")

        for path in paths {
            let packets = try benchmarkPackets(url: URL(fileURLWithPath: path))
            let duration = packets.reduce(0.0) { $0 + Double($1.samples.count) / $1.sampleRate }
            for _ in 0..<2 {
                try Task.checkCancellation()
                await manager.reset()
                let resampler = StreamingAudioResampler()
                let release = try await replayBenchmarkCapture(packets) { packet in
                    let samples = try await resampler.resample(packet.samples, from: packet.sampleRate)
                    if !samples.isEmpty { _ = try await manager.process(samples: samples) }
                }
                let drained = ContinuousClock.now
                let text = try await manager.finish()
                let ready = ContinuousClock.now
                print(String(format: "%5.2fs | drain %6.1f ms | finish %6.1f ms | text ready %6.1f ms | %d words",
                             duration, milliseconds(release.duration(to: drained)),
                             milliseconds(drained.duration(to: ready)), milliseconds(release.duration(to: ready)),
                             text.split(whereSeparator: \.isWhitespace).count))
                if printTranscript { print(text) }
            }
        }
    }
}

private struct NemotronBenchmarkError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
