@_spi(Validation) import ProsodyCore
@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation

extension ProsodyValidation {
    /// Measures the candidate's short-lived model lifecycle with generated
    /// audio only. It never opens a microphone, inserts text, or reads history.
    static func benchmarkDictationLifecycle(arguments: [String]) async throws {
        if arguments == ["--help"] {
            emitLifecycle(DictationLifecycleOptions.usage)
            return
        }
        let options = try DictationLifecycleOptions(arguments)
        let modelURL = try await installedDictationModelURL()
        let packets = try benchmarkPackets(url: options.fixture)
        let duration = packets.reduce(0.0) { $0 + Double($1.samples.count) / $1.sampleRate }
        guard duration >= DictationAudioPipeline.minimumDuration else {
            throw BenchmarkError("The lifecycle fixture must contain at least 250 ms of audio.")
        }
        let reference = try options.reference.map { path in
            lifecycleWords(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))
        }
        guard reference?.isEmpty != true else {
            throw BenchmarkError("The lifecycle reference contains no words.")
        }

        emitLifecycle("Dictation lifecycle benchmark | macOS \(ProcessInfo.processInfo.operatingSystemVersionString) | \(machineArchitecture())")
        emitLifecycle("Model: \(displayLifecyclePath(modelURL)) | fixture: \(options.fixture.lastPathComponent) | \(String(format: "%.3fs", duration)) | generated audio only")
        emitLifecycle("Core ML state: existing compiled .mlmodelc and OS caches are reused; no cache deletion or mutation is performed.")
        emitLifecycle("Retention trials: \(options.retentions.map { String(format: "%.1fs", $0) }.joined(separator: ", "))")

        if !options.skipFakeChecks {
            try await checkDeterministicLifecycle()
        }
        try await runRealLifecycle(options: options, packets: packets, reference: reference)
        if options.baselineLoader {
            try await runBaselineLoaderControl(modelURL: modelURL)
        }
        emitLifecycle("Dictation lifecycle benchmark: PASS")
    }

    private static func installedDictationModelURL() async throws -> URL {
        let registry = STTRegistry()
        guard let model = await registry.model(id: "parakeet-unified", for: .parakeet) else {
            throw BenchmarkError("Parakeet Unified is not registered.")
        }
        let inventory = STTModelManager()
        guard await inventory.isInstalled(model) else {
            throw BenchmarkError("Install Parakeet Unified in Prosody Settings → Models before benchmarking.")
        }
        return await inventory.modelURL(for: model)
    }

    private static func runRealLifecycle(
        options: DictationLifecycleOptions,
        packets: [CapturedAudioPacket],
        reference: [String]?
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prosody-Dictation-Lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        emitLifecycle("Real model: cold utterance, warm utterance, and back-to-back utterance")
        let utteranceRecognizer = DictationRecognizer(idleRetention: .seconds(options.primaryRetention))
        let cold = try await measuredLifecycle("cold_utterance") {
            try await runLifecyclePipeline(
                label: "cold-utterance", root: root, recognizer: utteranceRecognizer,
                packets: packets, paced: true, showText: options.showText
            )
        }
        try checkLifecycleRun(cold, reference: reference, context: "cold utterance")
        let warm = try await measuredLifecycle("warm_utterance") {
            try await runLifecyclePipeline(
                label: "warm-utterance", root: root, recognizer: utteranceRecognizer,
                packets: packets, paced: true, showText: options.showText
            )
        }
        try checkLifecycleRun(warm, reference: reference, context: "warm utterance")
        let backToBack = try await measuredLifecycle("back_to_back_utterance") {
            try await runLifecyclePipeline(
                label: "back-to-back", root: root, recognizer: utteranceRecognizer,
                packets: packets, paced: false, showText: options.showText
            )
        }
        try checkLifecycleRun(backToBack, reference: reference, context: "back-to-back utterance")
        try await measuredLifecycle("release_after_utterances") {
            await utteranceRecognizer.releaseIfIdle()
            try await Task.sleep(for: .milliseconds(250))
        }

        emitLifecycle("Real model: launch prepare enqueue and wait")
        let launchRecognizer = DictationRecognizer(idleRetention: .seconds(options.primaryRetention))
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        await launchRecognizer.prepare()
        let enqueueMilliseconds = elapsedMilliseconds(since: prepareStart)
        emitLifecycle(String(format: "phase=launch_prepare_enqueue | elapsed_ms=%.3f", enqueueMilliseconds))
        try await measuredLifecycle("launch_prepare_wait") {
            try await launchRecognizer.waitUntilPrepared()
        }
        let launchLoadMilliseconds = elapsedMilliseconds(since: prepareStart)
        emitLifecycle(String(format: "phase=launch_prepare_ready | elapsed_ms=%.1f | specialization=not_inferred",
                             launchLoadMilliseconds))
        let launchPhrase = try await measuredLifecycle("launch_first_phrase") {
            try await runLifecyclePipeline(
                label: "launch-first-phrase", root: root, recognizer: launchRecognizer,
                packets: packets, paced: true, showText: options.showText
            )
        }
        try checkLifecycleRun(launchPhrase, reference: reference, context: "launch first phrase")
        await launchRecognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(500))

        emitLifecycle("Real model: idle reload phrase, prepare started at simulated gesture")
        let idleReloadRecognizer = DictationRecognizer(idleRetention: .seconds(options.primaryRetention))
        let gestureStart = DispatchTime.now().uptimeNanoseconds
        await idleReloadRecognizer.prepare()
        let idleReload = try await measuredLifecycle("idle_reload_phrase") {
            try await runLifecyclePipeline(
                label: "idle-reload-phrase", root: root, recognizer: idleReloadRecognizer,
                packets: packets, paced: true, showText: options.showText
            )
        }
        emitLifecycle(String(format: "phase=idle_reload_phrase | gesture_to_ready_ms=%.1f | release_to_ready_ms=%.1f",
                             elapsedMilliseconds(since: gestureStart), idleReload.readyMilliseconds))
        try checkLifecycleRun(idleReload, reference: reference, context: "idle reload phrase")
        await idleReloadRecognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(500))

        for retention in options.retentions {
            try await measureIdleExpiry(
                retention: retention, root: root, packets: packets, reference: reference,
                showText: options.showText
            )
        }

        emitLifecycle("Real model: releaseIfIdle while audio is still streaming")
        let streamingRecognizer = DictationRecognizer(idleRetention: .seconds(options.primaryRetention))
        try await streamingRecognizer.waitUntilPrepared()
        let streaming = try await measuredLifecycle("release_during_stream") {
            try await runLifecyclePipeline(
                label: "release-during-stream", root: root, recognizer: streamingRecognizer,
                packets: packets, paced: true, showText: options.showText,
                releaseAfterFirstChunk: true
            )
        }
        try checkLifecycleRun(streaming, reference: reference, context: "release during stream")
        await streamingRecognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(250))

        emitLifecycle("Real model: cancel a waiter during a cold in-flight load")
        let cancelRecognizer = DictationRecognizer(idleRetention: .seconds(options.primaryRetention))
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        await cancelRecognizer.prepare()
        try await Task.sleep(for: .milliseconds(2))
        let canceledWaiter = Task { try await cancelRecognizer.waitUntilPrepared() }
        try await Task.sleep(for: .milliseconds(5))
        canceledWaiter.cancel()
        let cancelIssued = DispatchTime.now().uptimeNanoseconds
        var cancelHit = false
        do {
            try await canceledWaiter.value
        } catch is CancellationError {
            cancelHit = true
        }
        let cancelResultMilliseconds = elapsedMilliseconds(since: cancelIssued)
        await cancelRecognizer.releaseIfIdle()
        let lateStart = DispatchTime.now().uptimeNanoseconds
        try await cancelRecognizer.waitUntilPrepared()
        let lateMilliseconds = elapsedMilliseconds(since: lateStart)
        emitLifecycle(String(format: "phase=cancel_cold_waiter | cancel_hit=%@ | cancel_to_result_ms=%.1f | late_join_ms=%.1f | total_ms=%.1f",
                             cancelHit ? "yes" : "no", cancelResultMilliseconds, lateMilliseconds,
                             elapsedMilliseconds(since: cancelStart)))
        await cancelRecognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(250))
    }

    private static func measureIdleExpiry(
        retention: Double,
        root: URL,
        packets: [CapturedAudioPacket],
        reference: [String]?,
        showText: Bool
    ) async throws {
        emitLifecycle(String(format: "Real model: idle retention %.1fs", retention))
        let recognizer = DictationRecognizer(idleRetention: .seconds(retention))
        try await measuredLifecycle("retention_\(Int(retention))_prepare") {
            try await recognizer.waitUntilPrepared()
        }
        let sampler = LifecycleResourceSampler(interval: .seconds(1))
        sampler.start()
        let idleStart = DispatchTime.now().uptimeNanoseconds
        let beforeExpiry = max(0, retention - 1)
        try await Task.sleep(for: .seconds(beforeExpiry))
        emitLifecycleResourcePoint("retention_\(Int(retention))_before_expiry", sampler.current(), elapsedMilliseconds(since: idleStart))
        try await Task.sleep(for: .seconds(2))
        emitLifecycleResourcePoint("retention_\(Int(retention))_after_expiry", sampler.current(), elapsedMilliseconds(since: idleStart))
        let idleSummary = await sampler.stop()
        emitLifecycleResource("retention_\(Int(retention))_idle", idleSummary, elapsedMilliseconds(since: idleStart))

        _ = try await measuredLifecycle("retention_\(Int(retention))_reprepare") {
            try await recognizer.waitUntilPrepared()
        }
        let afterExpiry = try await measuredLifecycle("retention_\(Int(retention))_warm_after_expiry") {
            try await runLifecyclePipeline(
                label: "retention-\(Int(retention))-warm", root: root, recognizer: recognizer,
                packets: packets, paced: true, showText: showText
            )
        }
        try checkLifecycleRun(afterExpiry, reference: reference, context: "warm after \(Int(retention))s expiry")
        await recognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(250))
    }

    private static func runBaselineLoaderControl(modelURL: URL) async throws {
        emitLifecycle("Baseline loader control: direct StreamingUnifiedAsrManager, same model files")
        let manager = StreamingUnifiedAsrManager()
        try await measuredLifecycle("baseline_loader_load") {
            try await manager.loadModels(from: modelURL)
        }
        try await measuredLifecycle("baseline_loader_idle_1s") {
            try await Task.sleep(for: .seconds(1))
        }
        try await measuredLifecycle("baseline_loader_cleanup") {
            await manager.cleanup()
        }
        try await measuredLifecycle("baseline_loader_reload") {
            try await manager.loadModels(from: modelURL)
        }
        await manager.cleanup()

        emitLifecycle("Baseline cancel control: direct real MLModel load, cancel waiter, wait for load")
        let cancelManager = StreamingUnifiedAsrManager()
        let load = Task { try await cancelManager.loadModels(from: modelURL) }
        try await Task.sleep(for: .milliseconds(5))
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        load.cancel()
        var cancelCompleted = false
        do {
            try await load.value
            cancelCompleted = true
        } catch {
            emitLifecycle("baseline_cancel_load_error=\(error.localizedDescription)")
        }
        emitLifecycle(String(format: "phase=baseline_cancel_waits_for_load | completed=%@ | cancel_to_result_ms=%.1f",
                             cancelCompleted ? "yes" : "no", elapsedMilliseconds(since: cancelStart)))
        await cancelManager.cleanup()
    }

    private static func runLifecyclePipeline(
        label: String,
        root: URL,
        recognizer: DictationRecognizer,
        packets: [CapturedAudioPacket],
        paced: Bool,
        showText: Bool,
        releaseAfterFirstChunk: Bool = false
    ) async throws -> LifecycleRun {
        let writer = AudioArchiveWriter(directoryURL: root.appendingPathComponent(label))
        let configuration = TranscriptSegmentationConfiguration()
        let recorder = LifecyclePhaseRecorder()
        let scope = UUID()
        let pipeline = DictationAudioPipeline(
            archive: writer,
            bufferCapacity: 256,
            recognize: { input in
                try await recognizer.transcribe(input, configuration: configuration, scope: scope) { phase in
                    recorder.record(phase)
                }
            },
            replay: { urls in
                try await recognizer.replayArchive(urls, configuration: configuration, scope: scope) { phase in
                    recorder.record(phase)
                }
            },
            finishScope: {
                await recognizer.finishScope(scope)
            }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let totalDuration = packets.reduce(0.0) { $0 + Double($1.samples.count) / $1.sampleRate }
        let scheduled = start + .seconds(totalDuration)
        var finalPacket = start
        do {
            for (index, packet) in packets.enumerated() {
                if paced {
                    let end = packet.presentationTime + Double(packet.samples.count) / packet.sampleRate
                    try await clock.sleep(until: start + .seconds(end), tolerance: .milliseconds(1))
                }
                if index == packets.count - 1 { finalPacket = clock.now }
                try await pipeline.append(packet)
                if releaseAfterFirstChunk && index == min(4, packets.count - 1) {
                    await recognizer.releaseIfIdle()
                }
            }
            let feedDone = clock.now
            let outcome = try await pipeline.finish()
            let ready = clock.now
            let text = outcome.map { lifecycleText($0.audio.transcript) } ?? ""
            let run = LifecycleRun(
                label: label,
                paced: paced,
                readyMilliseconds: milliseconds(scheduled.duration(to: ready)),
                feedDoneToReadyMilliseconds: milliseconds(feedDone.duration(to: ready)),
                finalPacketLagMilliseconds: milliseconds(scheduled.duration(to: finalPacket)),
                phaseTimeline: recorder.snapshot(),
                text: text,
                wordCount: lifecycleWords(text).count,
                usedArchive: outcome?.usedArchive == true,
                audioDuration: outcome?.audio.duration ?? 0
            )
            emitLifecycleRun(run, showText: showText)
            try await writer.discard()
            return run
        } catch {
            await pipeline.cancel()
            try? await writer.discard()
            throw error
        }
    }

    private static func checkLifecycleRun(_ run: LifecycleRun, reference: [String]?, context: String) throws {
        guard !run.usedArchive else {
            throw BenchmarkError("\(context): live recognition unexpectedly used archive fallback.")
        }
        guard let reference else { return }
        let words = lifecycleWords(run.text)
        let edits = lifecycleWordEditDistance(reference, words)
        let wer = Double(edits) / Double(reference.count)
        let tail = min(2, reference.count)
        guard wer <= 0.12, words.suffix(tail).elementsEqual(reference.suffix(tail)) else {
            throw BenchmarkError(String(format: "%@: WER %.1f%% (%d/%d); final words did not match.",
                                         context, wer * 100, edits, reference.count))
        }
        emitLifecycle(String(format: "quality=%@ | WER %.1f%% (%d/%d) | ending matched",
                             context, wer * 100, edits, reference.count))
    }

    private static func checkDeterministicLifecycle() async throws {
        emitLifecycle("Deterministic lifecycle checks: prepare, cancel waiter, release during flight, idle expiry")
        let gate = LifecycleGate()
        let started = LifecycleSignal()
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            await started.send()
            await gate.wait()
            return LifecycleProbeModel(counters: counters)
        }
        await recognizer.prepare()
        await started.wait()
        let waiter = Task { try await recognizer.waitUntilPrepared() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        var cancelHit = false
        do {
            try await waiter.value
        } catch is CancellationError {
            cancelHit = true
        }
        await recognizer.releaseIfIdle()
        let late = Task { try await recognizer.waitUntilPrepared() }
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()
        try await late.value
        let loadCount = await counters.loads
        guard cancelHit, loadCount == 1 else {
            throw BenchmarkError("Deterministic cold cancellation did not join the shared load (cancel_hit=\(cancelHit), loads=\(loadCount)).")
        }
        emitLifecycle("deterministic_cancel=PASS | cancel_hit=yes | shared_loads=1")
        await recognizer.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(50))

        let unloaded = LifecycleSignal()
        let ttlCounters = LifecycleCounters()
        let ttlModel = LifecycleProbeModel(counters: ttlCounters, unloaded: unloaded)
        let ttl = DictationRecognizer(idleRetention: .milliseconds(50)) {
            await ttlCounters.incrementLoad()
            return ttlModel
        }
        try await ttl.waitUntilPrepared()
        await unloaded.wait()
        try await ttl.waitUntilPrepared()
        let ttlLoads = await ttlCounters.loads
        guard ttlLoads == 2 else {
            throw BenchmarkError("Deterministic TTL check did not reload after expiry (loads=\(ttlLoads)).")
        }
        await ttl.releaseIfIdle()
        emitLifecycle("deterministic_ttl=PASS | one_shot_expiry=yes | reload_after_expiry=yes")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prosody-Scoped-Fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scopedCounters = LifecycleCounters()
        let scopedModel = LifecycleProbeModel(counters: scopedCounters)
        let scopedRecognizer = DictationRecognizer(idleRetention: .zero) {
            await scopedCounters.incrementLoad()
            return scopedModel
        }
        let scope = UUID()
        let writer = AudioArchiveWriter(directoryURL: root)
        let pipeline = DictationAudioPipeline(
            archive: writer,
            bufferCapacity: 8,
            recognize: { input in
                for await _ in input {}
                throw BenchmarkError("forced scoped fallback")
            },
            replay: { urls in
                try await scopedRecognizer.replayArchive(
                    urls, configuration: .init(), scope: scope
                )
            },
            finishScope: { await scopedRecognizer.finishScope(scope) }
        )
        try await pipeline.append(CapturedAudioPacket(
            source: .microphone, presentationTime: 0, sampleRate: 16_000,
            samples: Array(repeating: 0.1, count: 4_800)
        ))
        let outcome = try await pipeline.finish()
        let scopedLoads = await scopedCounters.loads
        guard outcome?.usedArchive == true, scopedLoads == 1 else {
            throw BenchmarkError("Scoped fallback did not reuse exactly one model load (loads=\(scopedLoads)).")
        }
        await scopedRecognizer.releaseIfIdle()
        emitLifecycle("deterministic_scoped_fallback=PASS | archive_replay=yes | model_loads=1")
    }

    private static func measuredLifecycle<T>(
        _ label: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        let sampler = LifecycleResourceSampler(interval: .milliseconds(50))
        sampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await operation()
            let summary = await sampler.stop()
            emitLifecycleResource(label, summary, elapsedMilliseconds(since: start))
            return value
        } catch {
            let summary = await sampler.stop()
            emitLifecycleResource(label + "_failed", summary, elapsedMilliseconds(since: start))
            throw error
        }
    }

    private static func emitLifecycleRun(_ run: LifecycleRun, showText: Bool) {
        if run.paced, run.readyMilliseconds >= 0 {
            emitLifecycle(String(format: "run=%@ | paced=yes | ready_ms=%.1f | feed_done_to_ready_ms=%.1f | final_packet_lag_ms=%.1f | words=%d | fallback=%@ | duration=%.3f",
                                 run.label, run.readyMilliseconds, run.feedDoneToReadyMilliseconds,
                                 run.finalPacketLagMilliseconds, run.wordCount,
                                 run.usedArchive ? "yes" : "no", run.audioDuration))
        } else {
            emitLifecycle(String(format: "run=%@ | paced=no | feed_done_to_ready_ms=%.1f | words=%d | fallback=%@ | duration=%.3f",
                                 run.label, run.feedDoneToReadyMilliseconds, run.wordCount,
                                 run.usedArchive ? "yes" : "no", run.audioDuration))
        }
        let phases = run.phaseTimeline.map { String(format: "%@@%.1fms", $0.name, $0.milliseconds) }.joined(separator: ",")
        emitLifecycle("phase_timeline=\(run.label) | \(phases.isEmpty ? "none" : phases)")
        if showText { emitLifecycle("text=\(run.label) | \(run.text)") }
    }

    private static func emitLifecycleResourcePoint(_ label: String, _ point: LifecycleResourcePoint, _ elapsed: Double) {
        emitLifecycle(String(format: "resource_point=%@ | elapsed_ms=%.1f | rss_mb=%.1f | footprint_mb=%.1f | lifetime_peak_footprint_mb=%.1f",
                             label, elapsed, point.residentBytes / 1_048_576, point.footprintBytes / 1_048_576,
                             point.lifetimePeakFootprintBytes / 1_048_576))
    }

    private static func emitLifecycleResource(_ label: String, _ summary: LifecycleResourceSummary, _ elapsed: Double) {
        emitLifecycle(String(format: "resource=%@ | elapsed_ms=%.1f | rss_mb=%.1f..%.1f max=%.1f | footprint_mb=%.1f..%.1f max=%.1f | lifetime_peak_footprint_mb=%.1f | cpu_pct=%.1f | samples=%d",
                             label, elapsed, summary.start.residentBytes / 1_048_576, summary.end.residentBytes / 1_048_576,
                             summary.maxResidentBytes / 1_048_576, summary.start.footprintBytes / 1_048_576,
                             summary.end.footprintBytes / 1_048_576, summary.maxFootprintBytes / 1_048_576,
                             summary.end.lifetimePeakFootprintBytes / 1_048_576, summary.cpuPercent, summary.samples))
    }

    fileprivate static func emitLifecycle(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func displayLifecyclePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "$HOME")
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct DictationLifecycleOptions {
    static let usage = """
        Usage: ProsodyValidation --benchmark-dictation-lifecycle --fixture AUDIO
          [--reference UTF8-TEXT] [--retention SECONDS]... [--baseline-loader]
          [--skip-fake-checks] [--show-text]

        Runs generated-audio-only lifecycle measurements against the installed
        Parakeet Unified model. No microphone, clipboard, history, or paste is
        used. The default retention trial is 20 seconds; repeat --retention to
        measure more than one value. --baseline-loader also runs a direct
        StreamingUnifiedAsrManager load/cleanup control on the same model files.
        """

    let fixture: URL
    let reference: String?
    let retentions: [Double]
    let baselineLoader: Bool
    let skipFakeChecks: Bool
    let showText: Bool
    var primaryRetention: Double { retentions.first ?? 20 }

    init(_ arguments: [String]) throws {
        var fixture: URL?
        var reference: String?
        var retentions: [Double] = []
        var baselineLoader = false
        var skipFakeChecks = false
        var showText = false
        var remaining = arguments[...]
        func value(after flag: String) throws -> String {
            guard let value = remaining.popFirst(), !value.hasPrefix("--") else {
                throw BenchmarkError("Missing value for \(flag).\n\(Self.usage)")
            }
            return value
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "--fixture": fixture = URL(fileURLWithPath: try value(after: argument))
            case "--reference": reference = try value(after: argument)
            case "--retention":
                guard let seconds = Double(try value(after: argument)), seconds >= 0.05, seconds <= 300 else {
                    throw BenchmarkError("--retention must be from 0.05 to 300 seconds.")
                }
                retentions.append(seconds)
            case "--baseline-loader": baselineLoader = true
            case "--skip-fake-checks": skipFakeChecks = true
            case "--show-text": showText = true
            default: throw BenchmarkError("Unknown lifecycle argument: \(argument)\n\(Self.usage)")
            }
        }
        guard let fixture else { throw BenchmarkError(Self.usage) }
        self.fixture = fixture
        self.reference = reference
        self.retentions = retentions.isEmpty ? [20] : retentions
        self.baselineLoader = baselineLoader
        self.skipFakeChecks = skipFakeChecks
        self.showText = showText
    }
}

private struct LifecycleRun {
    let label: String
    let paced: Bool
    let readyMilliseconds: Double
    let feedDoneToReadyMilliseconds: Double
    let finalPacketLagMilliseconds: Double
    let phaseTimeline: [LifecyclePhasePoint]
    let text: String
    let wordCount: Int
    let usedArchive: Bool
    let audioDuration: Double
}

private struct LifecyclePhasePoint {
    let name: String
    let milliseconds: Double
}

private final class LifecyclePhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var values: [LifecyclePhasePoint] = []

    func record(_ phase: DictationRecognitionPhase) {
        let name = switch phase {
        case .preparingModel: "preparingModel"
        case .transcribing: "transcribing"
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.lock()
        values.append(LifecyclePhasePoint(name: name, milliseconds: milliseconds))
        lock.unlock()
    }

    func snapshot() -> [LifecyclePhasePoint] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct LifecycleResourcePoint: Sendable {
    let uptimeNanoseconds: UInt64
    let residentBytes: Double
    let footprintBytes: Double
    let lifetimePeakFootprintBytes: Double
    let userNanoseconds: UInt64
    let systemNanoseconds: UInt64
}

private struct LifecycleResourceSummary: Sendable {
    let start: LifecycleResourcePoint
    let end: LifecycleResourcePoint
    let maxResidentBytes: Double
    let maxFootprintBytes: Double
    let cpuPercent: Double
    let samples: Int
}

private final class LifecycleResourceSampler: @unchecked Sendable {
    private let interval: Duration
    private let lock = NSLock()
    private var values: [LifecycleResourcePoint] = []
    private var task: Task<Void, Never>?

    init(interval: Duration) { self.interval = interval }

    func start() {
        append(currentPoint())
        task = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: self.interval) } catch { return }
                self.append(self.currentPoint())
            }
        }
    }

    func current() -> LifecycleResourcePoint { currentPoint() }

    func stop() async -> LifecycleResourceSummary {
        task?.cancel()
        _ = await task?.value
        task = nil
        append(currentPoint())
        let samples = snapshot()
        let first = samples.first ?? currentPoint()
        let last = samples.last ?? first
        let wall = max(1, last.uptimeNanoseconds - first.uptimeNanoseconds)
        let cpu = (last.userNanoseconds &- first.userNanoseconds) &+ (last.systemNanoseconds &- first.systemNanoseconds)
        return LifecycleResourceSummary(
            start: first,
            end: last,
            maxResidentBytes: samples.map(\.residentBytes).max() ?? last.residentBytes,
            maxFootprintBytes: samples.map(\.footprintBytes).max() ?? last.footprintBytes,
            cpuPercent: Double(cpu) / Double(wall) * 100,
            samples: samples.count
        )
    }

    private func append(_ point: LifecycleResourcePoint) {
        lock.lock()
        values.append(point)
        lock.unlock()
    }

    private func snapshot() -> [LifecycleResourcePoint] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private func currentPoint() -> LifecycleResourcePoint {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        var basic = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return LifecycleResourcePoint(
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            residentBytes: basicResult == KERN_SUCCESS ? Double(basic.resident_size) : 0,
            footprintBytes: usageResult == 0 ? Double(usage.ri_phys_footprint) : 0,
            lifetimePeakFootprintBytes: usageResult == 0 ? Double(usage.ri_lifetime_max_phys_footprint) : 0,
            userNanoseconds: usageResult == 0 ? usage.ri_user_time : 0,
            systemNanoseconds: usageResult == 0 ? usage.ri_system_time : 0
        )
    }
}

private actor LifecycleGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor LifecycleSignal {
    private var sent = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send() {
        sent = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if sent { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor LifecycleCounters {
    private(set) var loads = 0
    private(set) var resets = 0
    private(set) var unloads = 0

    func incrementLoad() { loads += 1 }
    func incrementReset() { resets += 1 }
    func incrementUnload() { unloads += 1 }
}

private actor LifecycleProbeModel: DictationRecognitionModel {
    private let counters: LifecycleCounters
    private let unloaded: LifecycleSignal?

    init(counters: LifecycleCounters, unloaded: LifecycleSignal? = nil) {
        self.counters = counters
        self.unloaded = unloaded
    }

    func makeDictationSession(configuration: TranscriptSegmentationConfiguration) async throws -> any DictationRecognitionSession {
        LifecycleProbeSession()
    }

    func reset() async throws { await counters.incrementReset() }

    func unload() async {
        await counters.incrementUnload()
        await unloaded?.send()
    }
}

private actor LifecycleProbeSession: DictationRecognitionSession {
    func append(samples: [Float], startTime: TimeInterval) async throws {}

    func finishDictation(appending samples: [Float], startTime: TimeInterval, endTime: TimeInterval) async throws -> FinalTranscript {
        FinalTranscript(segments: [
            TranscriptSegment(source: .microphone, start: startTime, end: endTime, text: "lifecycle probe", isFinal: true)
        ])
    }

    func cancel() async {}
}

private func lifecycleText(_ transcript: Transcript) -> String {
    transcript.visibleSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func lifecycleWords(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "’", with: "")
        .replacingOccurrences(of: "'", with: "")
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
}

private func lifecycleWordEditDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
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
