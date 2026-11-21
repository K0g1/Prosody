@preconcurrency import AVFoundation
import Foundation

public enum AudioArchiveWriterError: Error, LocalizedError, Equatable, Sendable {
    case invalidPacket
    case cannotCreateFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPacket: return "The captured audio packet is invalid."
        case .cannotCreateFile(let message): return message
        }
    }
}

public enum AudioArchiveMergerError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedLocation(URL)
    case destinationIsDirectory(URL)
    case conflictingArtifact(source: URL, destination: URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let url):
            return "Recovery audio is not stored in a supported source directory: \(url.lastPathComponent)."
        case .destinationIsDirectory(let url):
            return "The retained audio destination is a directory: \(url.lastPathComponent)."
        case .conflictingArtifact(let source, let destination):
            return "Recovery audio \(source.lastPathComponent) conflicts with the retained copy \(destination.lastPathComponent)."
        }
    }
}

/// Merges independently valid archive chunks into a retained session without
/// replacing or deleting an existing retained chunk. Only direct legacy CAF
/// files and direct files in known source directories are considered.
enum AudioArchiveMerger {
    static func recoveryAudioFiles(in audioDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioDirectory.path) else { return [] }

        var files: [URL] = []
        let direct = try fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        files += direct.filter {
            $0.pathExtension.caseInsensitiveCompare("caf") == .orderedSame && isSupportedAudioFile($0)
        }

        for source in AudioSource.allCases {
            let sourceDirectory = audioDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            files += try supportedFiles(in: sourceDirectory)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func supportedFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter(isSupportedAudioFile).sorted { $0.path < $1.path }
    }

    static func merge(
        _ sourceFiles: [URL],
        from sourceAudioDirectory: URL,
        into finalAudioDirectory: URL
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let sourceRoot = sourceAudioDirectory.standardizedFileURL
        let finalRoot = finalAudioDirectory.standardizedFileURL
        guard sourceRoot != finalRoot else { return [] }
        let validSourceFiles = sourceFiles.filter(isSupportedAudioFile)
        guard !validSourceFiles.isEmpty else { return [] }

        try fileManager.createDirectory(at: finalRoot, withIntermediateDirectories: true)
        var planned: [(source: URL, destination: URL, alreadyRetained: Bool)] = []
        for sourceURL in validSourceFiles.sorted(by: { $0.path < $1.path }) {
            guard isWithin(sourceURL, root: sourceRoot) else {
                throw AudioArchiveMergerError.unsupportedLocation(sourceURL)
            }

            let sourceDirectory = sourceURL.deletingLastPathComponent()
            let destinationDirectory: URL
            if sourceDirectory.standardizedFileURL == sourceRoot {
                let sourceName = sourceURL.deletingPathExtension().lastPathComponent
                destinationDirectory = AudioSource(rawValue: sourceName) == nil
                    ? finalRoot
                    : finalRoot.deletingLastPathComponent()
            } else if sourceDirectory.deletingLastPathComponent().standardizedFileURL == sourceRoot,
                      AudioSource(rawValue: sourceDirectory.lastPathComponent) != nil {
                destinationDirectory = finalRoot.appendingPathComponent(
                    sourceDirectory.lastPathComponent,
                    isDirectory: true
                )
            } else {
                throw AudioArchiveMergerError.unsupportedLocation(sourceURL)
            }

            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destination = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    throw AudioArchiveMergerError.destinationIsDirectory(destination)
                }
                guard confidentlyIdentical(sourceURL, destination) else {
                    throw AudioArchiveMergerError.conflictingArtifact(source: sourceURL, destination: destination)
                }
                planned.append((sourceURL, destination, true))
            } else {
                planned.append((sourceURL, destination, false))
            }
        }

        // Check the entire batch before moving any chunk. A later conflicting
        // destination should leave the source archive intact for retry.
        var moved: [URL] = []
        for (source, destination, alreadyRetained) in planned {
            if alreadyRetained {
                guard confidentlyIdentical(source, destination) else {
                    throw AudioArchiveMergerError.conflictingArtifact(source: source, destination: destination)
                }
                try fileManager.removeItem(at: source)
                continue
            }
            try fileManager.moveItem(at: source, to: destination)
            moved.append(destination)
        }
        return moved
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        guard SessionAssetResolver.audioFileExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0
        else { return false }
        return true
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func confidentlyIdentical(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftValues = try? lhs.resourceValues(forKeys: [.fileSizeKey]),
              let rightValues = try? rhs.resourceValues(forKeys: [.fileSizeKey]),
              let leftSize = leftValues.fileSize,
              let rightSize = rightValues.fileSize,
              leftSize == rightSize else { return false }
        return FileManager.default.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }
}

/// Writes optional source audio as independently-valid AAC/M4A chunks. The
/// writer is an actor so AVAudioFile and its PCM buffers never cross actor
/// boundaries. A chunk is closed at roughly sixty seconds, which bounds the
/// amount of audio lost if Prosody exits unexpectedly.
public actor AudioArchiveWriter {
    // ExtAudioFile's mono M4A encoder can reject rates above 48 kHz on the
    // first write even when the file initializer and bitrate probe succeed.
    private static let archiveSampleRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    private static let fallbackSampleRate = 48_000.0

    public let directoryURL: URL
    private let bitRate: Int

    private var files: [AudioSource: AVAudioFile] = [:]
    private var fileURLs: [AudioSource: [URL]] = [:]
    private var framesInChunk: [AudioSource: Int] = [:]
    private var nextChunkIndex: [AudioSource: Int] = [:]
    private var sampleRates: [AudioSource: Double] = [:]
    private var resamplers: [AudioSource: MonoPCMResampler] = [:]

    public init(directoryURL: URL, bitRate: Int = 96_000) {
        self.directoryURL = directoryURL
        self.bitRate = min(max(bitRate, 32_000), 320_000)
    }

    public func append(_ packet: CapturedAudioPacket) throws {
        guard packet.sampleRate.isFinite, packet.sampleRate > 0,
              !packet.samples.isEmpty,
              packet.samples.allSatisfy(\.isFinite)
        else { throw AudioArchiveWriterError.invalidPacket }

        let source = packet.source
        // Preserve native rates supported by the archive encoder. Reject
        // tiny fluctuations when matching a nominal hardware sample rate.
        let inputRate = Self.archiveSampleRates.first { abs($0 - packet.sampleRate) < 0.5 } ?? packet.sampleRate
        let archiveRate = Self.archiveSampleRates.contains(inputRate) ? inputRate : Self.fallbackSampleRate
        if sampleRates[source] != inputRate {
            try finishResampling(for: source)
            closeCurrentChunk(for: source)
            if inputRate != archiveRate {
                resamplers[source] = try MonoPCMResampler(from: inputRate, to: archiveRate, primeMethod: .normal)
            }
            sampleRates[source] = inputRate
        }
        let samples = try resamplers[source]?.resample(packet.samples) ?? packet.samples
        try append(samples, for: source, sampleRate: archiveRate)
    }

    private func append(_ samples: [Float], for source: AudioSource, sampleRate: Double) throws {
        let chunkFrameLimit = Int((AppConstants.archiveSegmentSeconds * sampleRate).rounded(.down))
        var offset = 0
        while offset < samples.count {
            let written = framesInChunk[source, default: 0]
            let count = min(chunkFrameLimit - written, samples.count - offset)
            if let file = files[source] {
                try write(samples[offset..<(offset + count)], to: file)
            } else {
                try openChunk(for: source, sampleRate: sampleRate, firstSamples: samples[offset..<(offset + count)])
            }
            framesInChunk[source] = written + count
            offset += count

            if written + count >= chunkFrameLimit {
                closeCurrentChunk(for: source)
            }
        }
    }

    /// Closes the current files and returns every completed and in-progress
    /// chunk. The URLs remain available for moveArtifacts or discard.
    public func finish() throws -> [URL] {
        defer { closeFiles() }
        for source in AudioSource.allCases {
            try finishResampling(for: source)
        }
        return allFileURLs()
    }

    /// Closes temporary files and removes them after the final transcript has
    /// been committed when the user has disabled audio retention.
    public func discard() throws {
        closeFiles()
        fileURLs.removeAll()
        nextChunkIndex.removeAll()
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    /// Moves completed chunks from the recovery directory into the final
    /// session directory. Missing files are harmless for a silent source, and
    /// an existing valid destination chunk is preserved on retry.
    public func moveArtifacts(to finalDirectoryURL: URL) throws -> [URL] {
        let urls = try finish()
        let finalAudioDirectory = finalDirectoryURL.appendingPathComponent("audio", isDirectory: true)
        return try AudioArchiveMerger.merge(
            urls,
            from: directoryURL,
            into: finalAudioDirectory
        )
    }

    private func openChunk(for source: AudioSource, sampleRate: Double, firstSamples: ArraySlice<Float>) throws {
        let fileManager = FileManager.default
        let sourceDirectory = directoryURL.appendingPathComponent(source.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let index = nextChunkIndex[source, default: 0] + 1
        let url = sourceDirectory.appendingPathComponent(String(format: "%06d.m4a", index))
        guard !fileManager.fileExists(atPath: url.path) else {
            throw AudioArchiveWriterError.cannotCreateFile("An audio chunk already exists at \(url.lastPathComponent).")
        }

        var settings: [String: Any] = [
            AVAudioFileTypeKey: Int(kAudioFileM4AType),
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        if let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate, channels: 1, interleaved: false),
           let output = AVAudioFormat(settings: settings),
           let encoder = AVAudioConverter(from: input, to: output),
           let rates = encoder.applicableEncodeBitRates?.map(\.intValue).filter({ $0 > 0 }),
           let selectedRate = rates.filter({ $0 <= bitRate }).max() ?? rates.min() {
            settings[AVEncoderBitRateKey] = selectedRate
        }

        // The on-disk encoder can reject settings accepted by AVAudioConverter.
        // Commit the chunk index only after audio has been accepted.
        let file: AVAudioFile
        do {
            do {
                file = try createChunk(at: url, settings: settings, firstSamples: firstSamples)
            } catch where settings.removeValue(forKey: AVEncoderBitRateKey) != nil {
                file = try createChunk(at: url, settings: settings, firstSamples: firstSamples)
            }
        } catch {
            throw AudioArchiveWriterError.cannotCreateFile(
                "Could not write the \(source.rawValue) audio file at \(Int(sampleRate)) Hz: \(error.localizedDescription)"
            )
        }
        files[source] = file
        fileURLs[source, default: []].append(url)
        nextChunkIndex[source] = index
    }

    private func createChunk(
        at url: URL, settings: [String: Any], firstSamples: ArraySlice<Float>
    ) throws -> AVAudioFile {
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            do {
                try write(firstSamples, to: file)
            } catch {
                file.close()
                throw error
            }
            return file
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private func write(_ samples: ArraySlice<Float>, to file: AVAudioFile) throws {
        guard let frames = AVAudioFrameCount(exactly: samples.count), frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { throw AudioArchiveWriterError.invalidPacket }

        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { channel.update(from: address, count: source.count) }
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioArchiveWriterError.cannotCreateFile(error.localizedDescription)
        }
    }

    private func finishResampling(for source: AudioSource) throws {
        guard let resampler = resamplers.removeValue(forKey: source) else { return }
        // AVAudioConverter can retain the last frames even after accepting all
        // input. Drain them before finalizing this source's last chunk.
        let tail = try resampler.finish()
        try append(tail, for: source, sampleRate: Self.fallbackSampleRate)
    }

    private func closeCurrentChunk(for source: AudioSource) {
        files.removeValue(forKey: source)?.close()
        framesInChunk.removeValue(forKey: source)
    }

    private func closeFiles() {
        for file in files.values { file.close() }
        files.removeAll()
        framesInChunk.removeAll()
        sampleRates.removeAll()
        resamplers.removeAll()
    }

    private func allFileURLs() -> [URL] {
        fileURLs.values
            .flatMap { $0 }
            .sorted { $0.path < $1.path }
    }
}
