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
        var moved: [URL] = []
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
                if confidentlyIdentical(sourceURL, destination) {
                    try fileManager.removeItem(at: sourceURL)
                    continue
                }
                throw AudioArchiveMergerError.conflictingArtifact(source: sourceURL, destination: destination)
            }

            try fileManager.moveItem(at: sourceURL, to: destination)
            moved.append(destination)
        }
        return moved
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        guard SessionAssetResolver.audioFileExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
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
    public let directoryURL: URL
    private let bitRate: Int

    private var files: [AudioSource: AVAudioFile] = [:]
    private var fileURLs: [AudioSource: [URL]] = [:]
    private var framesInChunk: [AudioSource: Int] = [:]
    private var nextChunkIndex: [AudioSource: Int] = [:]
    private var sampleRates: [AudioSource: Double] = [:]

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
        if let existingRate = sampleRates[source],
           abs(existingRate - packet.sampleRate) > 0.5 {
            closeCurrentChunk(for: source)
        }
        sampleRates[source] = packet.sampleRate

        let chunkFrameLimit = max(
            1,
            Int((AppConstants.archiveSegmentSeconds * packet.sampleRate).rounded(.down))
        )
        var offset = 0
        while offset < packet.samples.count {
            let written = framesInChunk[source, default: 0]
            let available = max(1, chunkFrameLimit - written)
            let count = min(available, packet.samples.count - offset)
            let file = try openFileIfNeeded(for: source, sampleRate: packet.sampleRate)
            try write(
                packet.samples,
                offset: offset,
                count: count,
                to: file
            )
            framesInChunk[source, default: 0] += count
            offset += count

            if framesInChunk[source, default: 0] >= chunkFrameLimit {
                closeCurrentChunk(for: source)
            }
        }
    }

    /// Closes the current files and returns every completed and in-progress
    /// chunk. The URLs remain available for moveArtifacts or discard.
    public func finish() throws -> [URL] {
        files.removeAll()
        return allFileURLs()
    }

    /// Closes temporary files and removes them after the final transcript has
    /// been committed when the user has disabled audio retention.
    public func discard() throws {
        files.removeAll()
        fileURLs.removeAll()
        framesInChunk.removeAll()
        nextChunkIndex.removeAll()
        sampleRates.removeAll()
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    /// Moves completed chunks from the recovery directory into the final
    /// session directory. Missing files are harmless for a silent source, and
    /// an existing valid destination chunk is preserved on retry.
    public func moveArtifacts(to finalDirectoryURL: URL) throws -> [URL] {
        files.removeAll()
        let finalAudioDirectory = finalDirectoryURL.appendingPathComponent("audio", isDirectory: true)
        return try AudioArchiveMerger.merge(
            allFileURLs(),
            from: directoryURL,
            into: finalAudioDirectory
        )
    }

    private func openFileIfNeeded(for source: AudioSource, sampleRate: Double) throws -> AVAudioFile {
        if let file = files[source] {
            return file
        }

        let sourceDirectory = directoryURL.appendingPathComponent(source.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let index = nextChunkIndex[source, default: 0] + 1
        let url = sourceDirectory.appendingPathComponent(String(format: "%06d.m4a", index))
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        // Microphones can deliver native 8/16/24 kHz PCM even when system
        // capture uses 48 kHz. AAC rejects the requested quality bitrate when
        // it exceeds the limits for that format (Core Audio '!dat'). Query
        // the actual encoder instead of assuming every rate supports 96/192 kbps.
        // If it cannot report applicable rates, keep its format-specific default.
        if let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate, channels: 1, interleaved: false),
           let output = AVAudioFormat(settings: settings),
           let encoder = AVAudioConverter(from: input, to: output),
           let rates = encoder.applicableEncodeBitRates?.map(\.intValue).filter({ $0 > 0 }),
           let selectedRate = rates.filter({ $0 <= bitRate }).max() ?? rates.min() {
            settings[AVEncoderBitRateKey] = selectedRate
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            files[source] = file
            fileURLs[source, default: []].append(url)
            nextChunkIndex[source] = index
            framesInChunk[source] = 0
            return file
        } catch {
            throw AudioArchiveWriterError.cannotCreateFile(
                "Could not create the \(source.rawValue) audio file at \(Int(sampleRate)) Hz: \(error.localizedDescription)")
        }
    }

    private func write(
        _ samples: [Float],
        offset: Int,
        count: Int,
        to file: AVAudioFile
    ) throws {
        guard offset >= 0, count > 0, offset + count <= samples.count,
              let format = file.processingFormat as AVAudioFormat?,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { throw AudioArchiveWriterError.invalidPacket }

        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress.advanced(by: offset), count: count)
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioArchiveWriterError.cannotCreateFile(error.localizedDescription)
        }
    }

    private func closeCurrentChunk(for source: AudioSource) {
        files.removeValue(forKey: source)
        framesInChunk[source] = 0
    }

    private func allFileURLs() -> [URL] {
        fileURLs.values
            .flatMap { $0 }
            .sorted { $0.path < $1.path }
    }
}
