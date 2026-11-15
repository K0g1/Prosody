@_spi(Validation) import ProsodyCore
@preconcurrency import AVFoundation
import Foundation

extension ProsodyValidation {
    /// Compare the old file path and the actual streaming path on the same
    /// packets. Use a release build. No mic, clipboard, or history access.
    static func benchmarkDictation(arguments: [String]) async throws {
        if arguments == ["--help"] {
            print(DictationBenchmarkOptions.usage)
            return
        }
        let options = try DictationBenchmarkOptions(arguments)
        guard let model = await STTRegistry().model(id: "parakeet-unified", for: .parakeet),
              await STTModelManager().isInstalled(model) else {
            throw BenchmarkError("Install Parakeet Unified in Prosody Settings → Models before benchmarking.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prosody-Latency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        print("Parakeet Unified (installed only). Times in ms; no hardware capture or OS paste.")
        // Finish all live trials before starting any file-based model loads.
        // A file comparison must not warm or evict the live recognizer.
        let liveText = if options.archiveOnly { [[String]]() } else {
            try await benchmarkLive(options: options, root: root)
        }
        if !options.streamingOnly {
            try await benchmarkFile(options: options, root: root, liveText: liveText)
        }
        for (index, fixture) in options.fixtures.enumerated() where fixture.verifyFallback {
            try await benchmarkFallback(fixture, root: root.appendingPathComponent("fallback-\(index)"), options: options)
        }
        print("Dictation benchmark: PASS (all requested trials and quality checks completed)")
    }

    private static func benchmarkLive(options: DictationBenchmarkOptions, root: URL) async throws -> [[String]] {
        let retention: Duration = options.noCache ? .zero : .seconds(20)
        let recognizer = DictationRecognizer(idleRetention: retention)
        var previousModelUse: ContinuousClock.Instant?
        var transcripts: [[String]] = []
        print("Live: scheduled release to text ready. Cold uses a fresh recognizer cache; OS/Core ML caches may already be warm.")
        print("Warm indicates reuse within the cache window. Initial model load can overlap speech.")
        for (index, fixture) in options.fixtures.enumerated() {
            let packets = try benchmarkPackets(url: fixture.url)
            let duration = benchmarkDuration(packets)
            let canLoadModel = duration >= DictationAudioPipeline.minimumDuration &&
                packets.contains { $0.samples.contains { $0 != 0 } }
            print(String(format: "Fixture: %@ | %.3fs | %.0f Hz | %d live trials",
                         fixture.name, duration, packets[0].sampleRate, fixture.repeats))
            var text: [String] = []
            var timings: [String: [Double]] = [:]
            for trial in 1...fixture.repeats {
                let warm = previousModelUse.map { $0.duration(to: .now) < retention } ?? false
                let phase = canLoadModel ? (warm ? "warm" : "cold") : "no model"
                let writer = AudioArchiveWriter(directoryURL: root.appendingPathComponent("live-\(index)-\(trial)"))
                let pipeline = DictationAudioPipeline(archive: writer, recognizer: recognizer, configuration: .init())
                let outcome: (audio: AudioFileTranscription, usedArchive: Bool)?
                let release: BenchmarkCaptureRelease
                do {
                    release = try await pacedBenchmarkCapture(packets) { try await pipeline.append($0) }
                    outcome = try await pipeline.finish()
                } catch {
                    await pipeline.cancel()
                    throw error
                }
                let resultText = outcome.map { benchmarkText($0.audio.transcript) } ?? ""
                let ready = ContinuousClock.now
                let fallback = outcome?.usedArchive == true
                if fallback {
                    previousModelUse = nil
                } else if warm || (canLoadModel && outcome != nil) {
                    previousModelUse = ready
                }
                let elapsed = milliseconds(release.scheduled.duration(to: ready))
                let late = milliseconds(release.scheduled.duration(to: release.finalPacket))
                timings[fallback ? "unexpected fallback" : phase, default: []].append(elapsed)
                print(String(format: "  Live %d/%d [%@] | ready %.1f | final packet lag %.1f | %d words",
                             trial, fixture.repeats, fallback ? "\(phase), archive fallback" : phase,
                             elapsed, late, benchmarkWords(resultText).count))
                if options.showText { print("  Live text: \(resultText)") }
                let context = "\(fixture.name), live trial \(trial)"
                if fixture.reference != nil && fallback {
                    throw BenchmarkError("\(context): live recognition unexpectedly used archive fallback.")
                }
                try checkBenchmarkQuality(fixture, audio: outcome?.audio, text: resultText, duration: duration,
                                          archived: false, maxWER: options.maxWER, context: context)
                text.append(resultText)
                try await writer.discard()
            }
            for phase in ["cold", "warm", "no model", "unexpected fallback"] {
                printBenchmarkSummary("Live \(phase) ready", timings[phase, default: []])
            }
            transcripts.append(text)
        }
        return transcripts
    }

    private static func benchmarkFile(
        options: DictationBenchmarkOptions, root: URL, liveText: [[String]]
    ) async throws {
        print("File: previous release path, closing AAC and loading a new model before replay on every trial.")
        for (index, fixture) in options.fixtures.enumerated() where !fixture.expectNoOp {
            let packets = try benchmarkPackets(url: fixture.url)
            let duration = benchmarkDuration(packets)
            print("Fixture: \(fixture.name) | \(fixture.repeats) file trials")
            guard duration >= DictationAudioPipeline.minimumDuration else {
                if options.archiveOnly && fixture.reference != nil {
                    throw BenchmarkError("\(fixture.name): a reference fixture cannot be a short tap.")
                }
                print("  File skipped short tap")
                continue
            }
            var times: [Double] = []
            var loads: [Double] = []
            for trial in 1...fixture.repeats {
                let writer = AudioArchiveWriter(directoryURL: root.appendingPathComponent("file-\(index)-\(trial)"))
                for packet in packets.dropLast() { try await writer.append(packet) }
                let engine = TimedDictationEngine()
                let release = ContinuousClock.now
                try await writer.append(packets[packets.count - 1])
                let urls = try await writer.finish()
                let archiveClosed = ContinuousClock.now
                let audio = try await AudioFileTranscriber(engine: engine).transcribe(files: [.microphone: urls])
                let resultText = benchmarkText(audio.transcript)
                let ready = ContinuousClock.now
                let load = await engine.prepareTime
                times.append(milliseconds(release.duration(to: ready)))
                loads.append(milliseconds(load))
                let comparison = liveText.isEmpty ? "" :
                    (liveText[index][trial - 1] == resultText ? " | same text as Live" : " | text differs from Live")
                print(String(format: "  File %d/%d | archive %.1f | model load %.1f | replay %.1f | ready %.1f | %d words",
                             trial, fixture.repeats, milliseconds(release.duration(to: archiveClosed)), milliseconds(load),
                             milliseconds(archiveClosed.duration(to: ready) - load),
                             milliseconds(release.duration(to: ready)), benchmarkWords(resultText).count) + comparison)
                if options.showText { print("  File text: \(resultText)") }
                // In paired mode the old path is a diagnostic control. An old
                // truncated final word must not make the new live path fail.
                if options.archiveOnly {
                    try checkBenchmarkQuality(fixture, audio: audio, text: resultText, duration: duration,
                                              archived: true, maxWER: options.maxWER, context: "\(fixture.name), file trial \(trial)")
                }
                try await writer.discard()
            }
            printBenchmarkSummary("File ready", times)
            printBenchmarkSummary("File model load", loads)
        }
    }

    private static func benchmarkFallback(
        _ fixture: DictationBenchmarkOptions.Fixture, root: URL, options: DictationBenchmarkOptions
    ) async throws {
        let packets = try benchmarkPackets(url: fixture.url)
        let duration = benchmarkDuration(packets)
        let frames = packets.reduce(0) { $0 + $1.samples.count }
        let framesPerChunk = Int(packets[0].sampleRate * AppConstants.archiveSegmentSeconds)
        let expectedChunks = (frames + framesPerChunk - 1) / framesPerChunk
        let writer = AudioArchiveWriter(directoryURL: root)
        let engine = TimedDictationEngine()
        // Inject only the live recognition failure. Use the production
        // pipeline, AAC writer and Unified file transcriber for recovery.
        let pipeline = DictationAudioPipeline(archive: writer, bufferCapacity: packets.count, recognize: { input in
            for await _ in input { try Task.checkCancellation() }
            throw BenchmarkError("Injected live recognition failure")
        }, replay: { urls in
            guard urls.count == expectedChunks else {
                throw BenchmarkError("\(fixture.name): expected \(expectedChunks) fallback archive chunks; got \(urls.count).")
            }
            return try await AudioFileTranscriber(engine: engine).transcribe(files: [.microphone: urls])
        })
        print("Fixture: \(fixture.name) | forcing recognition failure (\(expectedChunks) AAC chunks expected)")
        do {
            // There is no inference to pace. Feed the complete archive before
            // timing fallback finalization so even a long check is practical.
            for packet in packets { try await pipeline.append(packet) }
            let release = ContinuousClock.now
            guard let outcome = try await pipeline.finish(), outcome.usedArchive else {
                throw BenchmarkError("\(fixture.name): injected recognition failure did not recover from the archive.")
            }
            let resultText = benchmarkText(outcome.audio.transcript)
            let ready = ContinuousClock.now
            let load = await engine.prepareTime
            print(String(format: "  Fallback | ready %.1f | model load %.1f | %d words",
                         milliseconds(release.duration(to: ready)), milliseconds(load), benchmarkWords(resultText).count))
            if options.showText { print("  Fallback text: \(resultText)") }
            try checkBenchmarkQuality(fixture, audio: outcome.audio, text: resultText, duration: duration,
                                      archived: true, maxWER: options.maxWER, context: "\(fixture.name), forced fallback")
            try await writer.discard()
        } catch {
            await pipeline.cancel()
            throw error
        }
    }

    static func replayBenchmarkCapture(
        _ packets: [CapturedAudioPacket],
        append: (CapturedAudioPacket) async throws -> Void
    ) async throws -> ContinuousClock.Instant {
        try await pacedBenchmarkCapture(packets, append: append).finalPacket
    }

    private struct BenchmarkCaptureRelease {
        let scheduled: ContinuousClock.Instant
        let finalPacket: ContinuousClock.Instant
    }

    private static func pacedBenchmarkCapture(
        _ packets: [CapturedAudioPacket],
        append: (CapturedAudioPacket) async throws -> Void
    ) async throws -> BenchmarkCaptureRelease {
        guard let last = packets.last else { throw BenchmarkError("No PCM to replay.") }
        let clock = ContinuousClock()
        let start = clock.now
        let scheduled = start + .seconds(last.presentationTime + Double(last.samples.count) / last.sampleRate)
        var finalPacket = start
        for (index, packet) in packets.enumerated() {
            let end = packet.presentationTime + Double(packet.samples.count) / packet.sampleRate
            try await clock.sleep(until: start + .seconds(end), tolerance: .milliseconds(1))
            if index == packets.count - 1 { finalPacket = clock.now }
            try await append(packet)
        }
        return BenchmarkCaptureRelease(scheduled: scheduled, finalPacket: finalPacket)
    }

    static func benchmarkPackets(url: URL) throws -> [CapturedAudioPacket] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate.isFinite, format.sampleRate >= 1_000,
              format.sampleRate <= 192_000, format.channelCount > 0,
              Double(file.length) / format.sampleRate <= 120,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 20)) else {
            throw BenchmarkError("Use a nonempty audio fixture up to two minutes long.")
        }
        var packets: [CapturedAudioPacket] = []
        while file.framePosition < file.length {
            let position = file.framePosition
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            var mono = Array(UnsafeBufferPointer(start: channels[0], count: count))
            if channelCount > 1 {
                for channel in 1..<channelCount {
                    for frame in 0..<count { mono[frame] += channels[channel][frame] }
                }
                for frame in 0..<count { mono[frame] /= Float(channelCount) }
            }
            packets.append(CapturedAudioPacket(source: .microphone, presentationTime: Double(position) / format.sampleRate,
                                               sampleRate: format.sampleRate, samples: mono))
        }
        guard !packets.isEmpty else { throw BenchmarkError("\(url.lastPathComponent): no PCM to replay.") }
        return packets
    }

    private static func benchmarkDuration(_ packets: [CapturedAudioPacket]) -> Double {
        packets.reduce(0.0) { $0 + Double($1.samples.count) / $1.sampleRate }
    }

    private static func checkBenchmarkQuality(
        _ fixture: DictationBenchmarkOptions.Fixture, audio: AudioFileTranscription?, text: String,
        duration: Double, archived: Bool, maxWER: Double, context: String
    ) throws {
        if fixture.expectNoOp {
            guard audio == nil else {
                throw BenchmarkError("\(context): expected no transcription result, got \(benchmarkWords(text).count) words.")
            }
            print("    Quality PASS: no transcription")
        }
        guard let reference = fixture.reference else { return }
        guard let audio else { throw BenchmarkError("\(context): expected speech, got no transcription.") }
        // AAC decoding may differ by a few frames at an archive boundary.
        guard abs(audio.duration - duration) <= (archived ? 0.10 : 0.001) else {
            throw BenchmarkError(String(format: "%@: returned %.3fs of %.3fs of input audio.", context, audio.duration, duration))
        }
        let words = benchmarkWords(text)
        let edits = wordEditDistance(reference, words)
        let wer = Double(edits) / Double(reference.count)
        let tail = min(2, reference.count)
        guard wer <= maxWER, words.suffix(tail).elementsEqual(reference.suffix(tail)) else {
            throw BenchmarkError(String(
                format: "%@: WER %.1f%% (%d edits / %d words, limit %.1f%%); final %d words %@.",
                context, wer * 100, edits, reference.count, maxWER * 100, tail,
                words.suffix(tail).elementsEqual(reference.suffix(tail)) ? "matched" : "did not match"
            ))
        }
        print(String(format: "    Quality PASS: WER %.1f%% (%d/%d), ending and duration match",
                     wer * 100, edits, reference.count))
    }

    private static func wordEditDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        var row = Array(0...hypothesis.count)
        for (offset, expected) in reference.enumerated() {
            var diagonal = row[0]
            row[0] = offset + 1
            for (index, actual) in hypothesis.enumerated() {
                let column = index + 1
                let previous = row[column]
                row[column] = min(previous + 1, row[column - 1] + 1, diagonal + (expected == actual ? 0 : 1))
                diagonal = previous
            }
        }
        return row[hypothesis.count]
    }

    private static func printBenchmarkSummary(_ label: String, _ times: [Double]) {
        guard !times.isEmpty else { return }
        let sorted = times.sorted()
        let n = sorted.count
        let median = (sorted[(n - 1) / 2] + sorted[n / 2]) / 2
        let summary = String(format: "  %@: n=%d | median %.1f | range %.1f–%.1f", label, n, median, sorted[0], sorted[n - 1])
        // With small samples, a p95 is effectively just the maximum.
        let p95 = n >= 20 ? String(format: " | p95 %.1f", sorted[Int(ceil(0.95 * Double(n))) - 1]) : ""
        print(summary + p95)
    }

    private static func benchmarkText(_ transcript: Transcript) -> String {
        transcript.visibleSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

private func benchmarkWords(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "’", with: "")
        .replacingOccurrences(of: "'", with: "")
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
}

private struct DictationBenchmarkOptions {
    static let usage = """
        Usage: ProsodyValidation --benchmark-dictation [--archive-only | --streaming-only]
          [--no-cache] [--show-text] [--max-wer FRACTION]
          [--repeat N] [--reference UTF8-TEXT | --expect-no-op] [--verify-fallback] AUDIO …

        --repeat applies to subsequent fixtures (default: 1). --reference and --expect-no-op
        apply to the next fixture only. A reference gates normalized word error rate (default:
        0.12), the final two words, input duration, and live use of PCM rather than fallback.
        --expect-no-op requires no transcription result. --verify-fallback requires a reference
        and runs a separate forced archive recovery check for that fixture. In paired mode the
        old file path is reported for comparison; reference gates apply to live and forced replay.
        """

    struct Fixture {
        let url: URL
        let repeats: Int
        let reference: [String]?
        let expectNoOp: Bool
        let verifyFallback: Bool
        var name: String { url.lastPathComponent }
    }

    var archiveOnly = false
    var streamingOnly = false
    var noCache = false
    var showText = false
    var maxWER = 0.12
    var fixtures: [Fixture] = []

    init(_ arguments: [String]) throws {
        var remaining = arguments[...]
        var repeats = 1
        var reference: [String]?
        var expectNoOp = false
        var verifyFallback = false
        func value(after flag: String) throws -> String {
            guard let value = remaining.popFirst(), !value.hasPrefix("--") else {
                throw BenchmarkError("Missing value for \(flag).\n\(Self.usage)")
            }
            return value
        }
        while let arg = remaining.popFirst() {
            switch arg {
            case "--archive-only": archiveOnly = true
            case "--streaming-only": streamingOnly = true
            case "--no-cache": noCache = true
            case "--show-text": showText = true
            case "--repeat":
                guard let count = Int(try value(after: arg)), (1...100).contains(count) else {
                    throw BenchmarkError("--repeat must be an integer from 1 to 100.")
                }
                repeats = count
            case "--max-wer":
                guard let fraction = Double(try value(after: arg)), (0...1).contains(fraction) else {
                    throw BenchmarkError("--max-wer must be a fraction from 0 to 1.")
                }
                maxWER = fraction
            case "--reference":
                guard reference == nil, !expectNoOp else { throw BenchmarkError(Self.usage) }
                let path = try value(after: arg)
                let words = try benchmarkWords(String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))
                guard !words.isEmpty else { throw BenchmarkError("Reference contains no words: \(path)") }
                reference = words
            case "--expect-no-op":
                guard reference == nil, !expectNoOp else { throw BenchmarkError(Self.usage) }
                expectNoOp = true
            case "--verify-fallback": verifyFallback = true
            default:
                guard !arg.hasPrefix("--"), !verifyFallback || reference != nil else { throw BenchmarkError(Self.usage) }
                fixtures.append(Fixture(url: URL(fileURLWithPath: arg), repeats: repeats, reference: reference,
                                        expectNoOp: expectNoOp, verifyFallback: verifyFallback))
                reference = nil
                expectNoOp = false
                verifyFallback = false
            }
        }
        guard !fixtures.isEmpty, !(archiveOnly && streamingOnly), reference == nil, !expectNoOp, !verifyFallback else {
            throw BenchmarkError(Self.usage)
        }
        guard !archiveOnly || !fixtures.contains(where: { $0.expectNoOp || $0.verifyFallback }) else {
            throw BenchmarkError("No-op and forced fallback checks require the live pipeline.")
        }
    }
}

struct BenchmarkError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

private actor TimedDictationEngine: STTEngine {
    nonisolated let descriptor: STTEngineDescriptor
    private let engine: ParakeetEngine
    private(set) var prepareTime: Duration = .zero

    init() {
        let engine = ParakeetEngine(segmentationConfiguration: .init())
        self.engine = engine
        descriptor = engine.descriptor
    }

    func prepare(model: STTModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        let start = ContinuousClock.now
        try await engine.prepare(model: model, progress: progress)
        prepareTime = start.duration(to: .now)
    }

    func makeSession(source: AudioSource) async throws -> any STTSession {
        try await engine.makeSession(source: source)
    }

    func unload() async { await engine.unload() }
}
