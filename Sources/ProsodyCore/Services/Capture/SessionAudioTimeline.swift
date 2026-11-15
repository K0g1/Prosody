import Foundation

public struct SessionAudioChunk: Equatable, Sendable {
    public let url: URL
    public let start: TimeInterval
    public let duration: TimeInterval

    public var end: TimeInterval { start + duration }

    public init(url: URL, start: TimeInterval, duration: TimeInterval) {
        self.url = url
        self.start = start
        self.duration = duration
    }
}

/// Cumulative source-clock map for retained audio chunks. Chunk starts are
/// computed once, and source lookup is a binary search rather than a scan from
/// the first file on every seek.
public struct SessionAudioTimeline: Equatable, Sendable {
    public let chunks: [SessionAudioChunk]
    public let duration: TimeInterval

    public init(urls: [URL], durations: [TimeInterval]) {
        var offset: TimeInterval = 0
        var mapped: [SessionAudioChunk] = []
        for (url, duration) in zip(urls, durations) {
            guard duration.isFinite, duration > 0 else { continue }
            mapped.append(SessionAudioChunk(url: url, start: offset, duration: duration))
            offset += duration
        }
        chunks = mapped
        self.duration = offset
    }

    public static let empty = SessionAudioTimeline(urls: [], durations: [])

    /// Numbered archive chunks form one source timeline. Once more than one
    /// numbered sibling is present, the sequence must start at 1 and remain
    /// contiguous; a gap would shift later audio away from transcript times.
    /// A lone arbitrary file, including a legacy CAF, has no siblings to
    /// validate. Mixed numbered and unnumbered files are rejected because
    /// their ordering is ambiguous.
    static func hasContiguousNumberedChunks(_ urls: [URL]) -> Bool {
        if urls.count == 1, let url = urls.first, isCanonicalArchiveChunk(url) {
            return chunkNumber(for: url) == 1
        }
        guard urls.count > 1 else { return true }

        let numbers = urls.compactMap { chunkNumber(for: $0) }
        guard !numbers.isEmpty else { return true }
        guard numbers.count == urls.count else { return false }
        return numbers.sorted() == Array(1...urls.count)
    }

    public func chunkIndex(containing time: TimeInterval) -> Int? {
        guard !chunks.isEmpty, !time.isNaN else { return nil }
        if time == .infinity { return chunks.count - 1 }

        let value = min(max(0, time), duration)
        var lower = 0
        var upper = chunks.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if chunks[middle].start <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, min(lower - 1, chunks.count - 1))
    }

    public func localTime(for time: TimeInterval, chunkIndex: Int) -> TimeInterval {
        guard chunks.indices.contains(chunkIndex), time.isFinite else { return 0 }
        let chunk = chunks[chunkIndex]
        return min(max(0, time - chunk.start), chunk.duration)
    }

    public func globalTime(chunkIndex: Int, localTime: TimeInterval) -> TimeInterval {
        guard chunks.indices.contains(chunkIndex), localTime.isFinite else { return 0 }
        let chunk = chunks[chunkIndex]
        return min(max(chunk.start, chunk.start + localTime), chunk.end)
    }

    private static func chunkNumber(for url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty,
              stem.allSatisfy({ $0.isNumber }),
              let number = Int(stem)
        else { return nil }
        return number
    }

    private static func isCanonicalArchiveChunk(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count == 6,
              stem.allSatisfy({ $0.isASCII && $0.isNumber }),
              url.pathExtension.lowercased() == "m4a"
        else { return false }

        let sourceDirectory = url.deletingLastPathComponent()
        let audioDirectory = sourceDirectory.deletingLastPathComponent()
        return ["system", "microphone"].contains(sourceDirectory.lastPathComponent)
            && audioDirectory.lastPathComponent == "audio"
    }
}
