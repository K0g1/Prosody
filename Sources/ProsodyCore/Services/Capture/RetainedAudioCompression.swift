@preconcurrency import AVFoundation
import Foundation

enum RetainedAudioCompression {
    static func storedBytes(in directory: URL) -> Int64 {
        SessionAssetResolver.allAudioTracks(in: directory).values.flatMap { $0 }.reduce(Int64.zero) {
            $0 + fileBytes($1)
        }
    }

    /// Prepare and validate replacement audio alongside the session. A single
    /// directory replacement commits it only after every track is readable.
    static func compress(in directory: URL) throws -> Int64 {
        let manager = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".compress-\(UUID())",
                                                                                 isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        do {
            // Stage metadata and untouched chunks with hard links on APFS.
            // The encoder always writes new files, so the original data and
            // any backups remain untouched until the final directory swap.
            try manager.linkItem(at: directory, to: staging)
        } catch {
            // Some external or network filesystems do not support hard links.
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            try manager.copyItem(at: directory, to: staging)
        }
        let stagedRoot = staging.resolvingSymlinksInPath().path + "/"
        let tracks = SessionAssetResolver.allAudioTracks(in: staging)
        var totalSaved: Int64 = 0
        for source in AudioSource.allCases {
            guard let files = tracks[source] else { continue }
            guard files.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(stagedRoot) }) else {
                throw STTError.failed("Move externally linked audio into the transcript folder before compressing.")
            }
            let track = staging.appendingPathComponent("audio/\(source.rawValue)", isDirectory: true)
            guard track.resolvingSymlinksInPath().path.hasPrefix(stagedRoot) else {
                throw STTError.failed("The audio folder points outside the transcript folder.")
            }
            try manager.createDirectory(at: track, withIntermediateDirectories: true)
            // Rename only inside the staging area. Stable sequence numbers
            // preserve playback across chunks even when extensions change.
            let scratch = staging.appendingPathComponent(".track-\(source.rawValue)", isDirectory: true)
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
            var replacements: [URL] = []
            for (index, original) in files.enumerated() {
                try Task.checkCancellation()
                let candidate = scratch.appendingPathComponent(String(format: "%06d.m4a", index + 1))
                try encode(original, to: candidate)
                let saving = fileBytes(original) - fileBytes(candidate)
                if saving > 0 {
                    replacements.append(candidate)
                    try manager.removeItem(at: original)
                    totalSaved += saving
                } else {
                    try manager.removeItem(at: candidate)
                    let sameFormat = candidate.deletingPathExtension().appendingPathExtension(original.pathExtension)
                    try manager.moveItem(at: original, to: sameFormat)
                    replacements.append(sameFormat)
                }
            }
            for replacement in replacements {
                let destination = track.appendingPathComponent(replacement.lastPathComponent)
                try manager.moveItem(at: replacement, to: destination)
            }
            try manager.removeItem(at: scratch)
        }
        guard totalSaved > 0 else { return 0 }
        try Task.checkCancellation()
        _ = try manager.replaceItemAt(directory, withItemAt: staging)
        return totalSaved
    }

    private static func encode(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 384_000,
              format.channelCount == 1 || format.channelCount == 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw STTError.failed("The audio format cannot be compressed without changing its channels.")
        }
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount)
        ]
        let bitRate = format.channelCount == 1 ? 48_000 : 80_000
        if let encoded = AVAudioFormat(settings: settings), let converter = AVAudioConverter(from: format, to: encoded),
           let rate = converter.applicableEncodeBitRates?.map(\.intValue).filter({ $0 > 0 && $0 <= bitRate }).max() {
            settings[AVEncoderBitRateKey] = rate
        }
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        let verified = try AVAudioFile(forReading: destination)
        let difference = abs(Double(verified.length) / verified.processingFormat.sampleRate - Double(input.length) / format.sampleRate)
        guard verified.length > 0, verified.processingFormat.channelCount == format.channelCount, difference <= 0.12 else {
            throw STTError.failed("The compressed audio could not be verified.")
        }
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
