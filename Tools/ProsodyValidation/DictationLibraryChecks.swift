import ProsodyCore
@preconcurrency import AVFoundation
import Foundation

extension ProsodyValidation {
    static func checkDictationAndLibrary() async throws {
        let processor = WordReplacementProcessor(rules: [
            .init(original: "clip pee", replacement: "Prosody"),
            .init(original: "cat", replacement: "dog"),
            .init(original: "dog", replacement: "$1\\literal"),
            .init(original: "cat food", replacement: "dinner"),
            .init(original: "C++", replacement: "C plus plus"),
            .init(original: "", replacement: "invalid")
        ])
        precondition(processor.apply(to: "CLIP PEE, cat catalog cat food dog C++.") == "Prosody, dog catalog dinner $1\\literal C plus plus.")
        precondition(WordReplacementProcessor(rules: [.init(original: "café", replacement: "coffee")]).apply(to: "Café cafés") == "coffee cafés")
        let label = RecordingLabel(name: "School").snapshot
        let old = SessionSummary(id: UUID(), title: "Zebra", createdAt: Date(timeIntervalSince1970: 1), duration: 5, labels: [label])
        let new = SessionSummary(id: UUID(), title: "Apple", createdAt: Date(timeIntervalSince1970: 2), duration: 10)
        for sort in [TranscriptSort.newest, .name, .longest] {
            precondition(TranscriptLibraryQuery.apply(to: [old, new], search: "", labelID: nil, sort: sort).first?.id == new.id)
        }
        for sort in [TranscriptSort.oldest, .shortest] {
            precondition(TranscriptLibraryQuery.apply(to: [old, new], search: "", labelID: nil, sort: sort).first?.id == old.id)
        }
        precondition(TranscriptLibraryQuery.apply(to: [old, new], search: "school", labelID: label.id, sort: .label) == [old])
        precondition(TranscriptLibraryQuery.apply(to: [old, new], search: "apple", labelID: label.id, sort: .label).isEmpty)
        checkTextAndThemePresentation()
        try await checkBoundedFileDecoding()
        await checkDictationPreferences()
        print("Dictation/library regressions: PASS (literal replacements, sort/filter, bounded decoding, cancellation, preferences)")
    }

    private static func checkTextAndThemePresentation() {
        let transcript = Transcript(segments: [
            .init(source: .system, start: 0, end: 1, text: "  First part.\n Continued.  ", isFinal: true, speakerName: "Alice"),
            .init(source: .microphone, start: 1, end: 2, text: "Echo", isFinal: true, isEchoDuplicate: true),
            .init(source: .microphone, start: 2, end: 3, text: "   ", isFinal: true),
            .init(source: .microphone, start: 3, end: 4, text: "Second\tpart.", isFinal: true, speakerName: "Bob")
        ])
        precondition(transcript.rawText == "First part. Continued.\n\nSecond part.")
        precondition(DictationOutput.insertionText("  Café 日本語.\n") == "Café 日本語. ")
        precondition(DictationOutput.insertionText("Hello. ") == "Hello. ")
        precondition(DictationOutput.insertionText(" \n").isEmpty)
        let permissionError: Error = UserFacingError(title: "Microphone required",
            message: "Allow Prosody to use the microphone in System Settings.")
        precondition(permissionError.localizedDescription == "Allow Prosody to use the microphone in System Settings.")
        precondition(DictationWaveform.amplitude(rms: .nan) == 0)
        precondition(DictationWaveform.amplitude(rms: 0) == 0)
        precondition(DictationWaveform.amplitude(rms: 0.03) > 0.5)
        for rms in [0.0, 0.003, 0.01, 0.1, 1] {
            let bars = DictationWaveform.bars(rms: rms, peak: rms)
            precondition(bars.count == 17 && bars.allSatisfy { $0.isFinite && (4...46).contains($0) })
        }
        let legacyThemeIDs: Set<String> = [
            "graphite", "pearl", "midnight", "aurora", "fjord", "tidal", "pine", "matcha",
            "dune", "terracotta", "rosewater", "plum", "amethyst", "copper", "solar",
            "linen", "sea-salt", "daybreak", "celadon", "lavender-mist", "apricot",
            "hibiscus", "cornflower", "citron", "opal", "obsidian", "blue-hour", "deep-sea",
            "lichen", "redwood", "espresso", "mulberry", "ultramarine", "eclipse",
            "verdigris", "glass"
        ]
        let expectedThemeIDs = legacyThemeIDs.union([
            "smoked-glass", "sea-glass", "clear-glass", "amber-glass", "iris-glass", "rose-glass",
            "cloud", "chalk", "canvas", "slate", "stone", "fog",
            "oled-true-black", "cobalt-ink", "navy-ink", "carbon-cyan", "ink-violet", "deep-navy",
            "royal-ink", "midnight-cyan", "ink-plum", "coastal-fog", "kelp", "moss", "fern",
            "rainforest", "glacier", "harbor", "lagoon", "driftwood", "evergreen", "risograph-red",
            "blueprint", "newsprint", "letterpress", "gouache", "watercolor", "vermilion", "cerulean",
            "magenta-press", "neon-nocturne", "signal-red", "signal-amber", "radar-green", "ultraviolet",
            "arcade", "laser-pink", "nightwatch", "beacon", "starlight", "basalt", "granite", "quartz",
            "clay", "ochre", "umber", "jade", "sandstone", "moss-agate"
        ])
        precondition(ProsodyTheme.allCases.count == 95)
        precondition(Set(ProsodyTheme.allCases.map(\.id)) == expectedThemeIDs)
        precondition(legacyThemeIDs.isSubset(of: Set(ProsodyTheme.allCases.map(\.id))))
        precondition(ProsodyTheme.allCases.filter { $0.isAdaptive } == [.glass, .clearGlass, .amberGlass, .irisGlass, .roseGlass])
        for theme in ProsodyTheme.allCases {
            let light = theme.palette(for: .light)
            let dark = theme.palette(for: .dark)
            precondition(light.colors.count == 9 && dark.colors.count == 9)
            if theme.isAdaptive {
                precondition(!light.dark && dark.dark && light.colors != dark.colors)
            } else {
                precondition(light == theme.palette && dark == theme.palette)
            }
            for palette in [light, dark] {
                let colors = palette.colors
                for background in 0..<4 {
                    for foreground in [7, 8] {
                        precondition(contrast(colors[foreground], colors[background]) >= 4.5,
                            "Low text contrast in \(theme.rawValue)")
                    }
                }
                for accent in [4, 5] {
                    precondition(contrast(colors[6], colors[accent]) >= 4.5,
                        "Low button contrast in \(theme.rawValue)")
                }
            }
        }
        print("Presentation regressions: PASS (95 theme contrast palettes with the 36-theme legacy set, raw copy, trailing space, waveform bounds)")
    }

    private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ shift: UInt32) -> Double {
                let channel = Double((hex >> shift) & 255) / 255.0
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return linear(16) * 0.2126 + linear(8) * 0.7152 + linear(0) * 0.0722
        }
        let values = [luminance(first), luminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    @MainActor
    private static func checkDictationPreferences() {
        let name = "Prosody-Dictation-Preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ProsodyPreferences(defaults: defaults)
        precondition(preferences.dictationShortcut == .rightCommand && preferences.dictationActivation == .hold)
        precondition(preferences.dictationOverlayAppearance == .standard)
        preferences.dictationShortcut = .rightOption
        preferences.dictationActivation = .toggle
        preferences.dictationOverlayAppearance = .minimal
        preferences.copyDictationToClipboard = true
        preferences.liveTranscription = false
        preferences.theme = .aurora
        preferences.dictationInsertionMethod = .typing
        preferences.wordReplacements = [.init(original: "test", replacement: "verified")]
        let restored = ProsodyPreferences(defaults: defaults)
        precondition(restored.dictationShortcut == .rightOption && restored.dictationActivation == .toggle)
        precondition(restored.dictationOverlayAppearance == .minimal)
        precondition(restored.copyDictationToClipboard && !restored.liveTranscription)
        precondition(restored.wordReplacements == preferences.wordReplacements)
        precondition(restored.theme == .aurora && restored.dictationInsertionMethod == .typing)
    }

    private static func checkBoundedFileDecoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-File-Test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("stereo.wav")
        // A non-16k stereo fixture exercises decoding, downmix, resampling,
        // multiple chunks, and the shorter final chunk without model downloads.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000)!
        buffer.frameLength = 120_000
        for channel in 0..<2 {
            for index in 0..<120_000 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.02) * 0.1) }
        }
        do { let file = try AVAudioFile(forWriting: fileURL, settings: format.settings); try file.write(from: buffer) }
        let engine = FileTestEngine()
        let result = try await AudioFileTranscriber(engine: engine).transcribe(files: [.microphone: [fileURL, fileURL]])
        precondition(abs(result.duration - 5) < 0.001)
        precondition(result.transcript.visibleSegments.first?.text == "decoded fixture")
        let calls = await engine.session.calls
        precondition(calls.count == 6 && calls.allSatisfy { $0.count <= 16_032 })
        precondition(abs(calls.map(\.count).reduce(0, +) - 80_000) <= 2)
        precondition(calls.map(\.start) == [0, 1, 2, 2.5, 3.5, 4.5])
        let unloaded = await engine.unloaded
        precondition(unloaded)
        let cancelledEngine = FileTestEngine()
        let task = Task {
            try await AudioFileTranscriber(engine: cancelledEngine).transcribe(files: [.system: [fileURL]])
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled file transcription returned output") }
        catch is CancellationError { }
        let cancellationUnloaded = await cancelledEngine.unloaded
        precondition(cancellationUnloaded)
    }
}

private actor FileTestEngine: STTEngine {
    nonisolated let descriptor = STTEngineDescriptor(id: .parakeet, displayName: "Fixture", detail: "Validation only")
    let session = FileTestSession()
    private(set) var unloaded = false
    func prepare(model: STTModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws { progress(1) }
    func makeSession(source: AudioSource) async throws -> any STTSession { session }
    func unload() async { unloaded = true }
}

private actor FileTestSession: STTSession {
    nonisolated let updates: AsyncStream<STTUpdate>
    private let continuation: AsyncStream<STTUpdate>.Continuation
    private(set) var calls: [(count: Int, start: TimeInterval)] = []
    init() {
        let stream = AsyncStream<STTUpdate>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
    }
    func append(samples: [Float], startTime: TimeInterval) async throws {
        precondition(samples.allSatisfy(\.isFinite))
        calls.append((samples.count, startTime))
    }
    func finish() async throws -> FinalTranscript {
        continuation.finish()
        return FinalTranscript(segments: [.init(source: .microphone, start: 0, end: 5, text: "decoded fixture", isFinal: true)])
    }
    func cancel() async { continuation.finish() }
}
