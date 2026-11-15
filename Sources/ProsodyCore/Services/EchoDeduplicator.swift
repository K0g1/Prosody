import Foundation

public struct EchoDeduplicationOptions: Codable, Equatable, Sendable {
    public var similarityThreshold: Double
    public var minimumTemporalOverlap: Double

    public init(similarityThreshold: Double = 0.85, minimumTemporalOverlap: Double = 0.5) {
        self.similarityThreshold = min(max(similarityThreshold, 0), 1)
        self.minimumTemporalOverlap = min(max(minimumTemporalOverlap, 0), 1)
    }
}

/// Pure echo matching algorithm. The raw segment is retained and only the
/// microphone copy is marked, allowing debugging and future re-processing.
public struct EchoDeduplication: Sendable {
    public let options: EchoDeduplicationOptions

    public init(options: EchoDeduplicationOptions = EchoDeduplicationOptions()) {
        self.options = options
    }

    public func markDuplicates(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result = segments
        let system = segments.filter { $0.source == .system && !$0.text.isEmpty }
        let microphoneIndices = segments.indices.filter {
            segments[$0].source == .microphone && !segments[$0].wasUserEdited && !segments[$0].text.isEmpty
        }

        for index in microphoneIndices {
            let microphoneSegment = segments[index]
            let duplicate = system.contains { systemSegment in
                guard temporalOverlapRatio(microphoneSegment, systemSegment) >= options.minimumTemporalOverlap else {
                    return false
                }
                return similarity(microphoneSegment.text, systemSegment.text) >= options.similarityThreshold
            }
            if duplicate {
                result[index].isEchoDuplicate = true
            }
        }
        return result
    }

    public func isDuplicate(microphone: TranscriptSegment, system: TranscriptSegment) -> Bool {
        microphone.source == .microphone
            && system.source == .system
            && temporalOverlapRatio(microphone, system) >= options.minimumTemporalOverlap
            && similarity(microphone.text, system.text) >= options.similarityThreshold
    }

    public func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedText(lhs)
        let right = normalizedText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }

        let leftTokens = Set(left.split(separator: " ").map(String.init))
        let rightTokens = Set(right.split(separator: " ").map(String.init))
        let unionCount = leftTokens.union(rightTokens).count
        let jaccard = unionCount == 0
            ? 0
            : Double(leftTokens.intersection(rightTokens).count) / Double(unionCount)
        let editSimilarity = normalizedEditSimilarity(left, right)
        return max(jaccard, editSimilarity)
    }

    public func normalizedText(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var output = ""
        output.reserveCapacity(folded.count)
        var previousWasSpace = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                output.append(" ")
                previousWasSpace = true
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func temporalOverlapRatio(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Double {
        let overlap = max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
        let lhsDuration = max(0, lhs.end - lhs.start)
        let rhsDuration = max(0, rhs.end - rhs.start)
        let shorter = min(lhsDuration, rhsDuration)
        if shorter == 0 {
            return lhs.start == rhs.start ? 1 : 0
        }
        return overlap / shorter
    }

    private func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for (i, leftCharacter) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, rightCharacter) in b.enumerated() {
                let substitution = previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(substitution, current[j] + 1, previous[j + 1] + 1))
            }
            previous = current
        }
        let distance = previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }
}

public actor EchoDeduplicator {
    private let algorithm: EchoDeduplication

    public init(options: EchoDeduplicationOptions = EchoDeduplicationOptions()) {
        self.algorithm = EchoDeduplication(options: options)
    }

    public func markDuplicates(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        algorithm.markDuplicates(in: segments)
    }

    public func isDuplicate(microphone: TranscriptSegment, system: TranscriptSegment) -> Bool {
        algorithm.isDuplicate(microphone: microphone, system: system)
    }
}
