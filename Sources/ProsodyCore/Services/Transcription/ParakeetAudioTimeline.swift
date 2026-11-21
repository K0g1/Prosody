import Foundation

/// Maps the contiguous samples delivered to the decoder back to the source
/// timeline. Small timestamp jitter stays on the current sample clock.
struct ParakeetAudioTimeline {
    private struct Anchor {
        let offset: TimeInterval
        let time: TimeInterval
    }

    private var anchors: [Anchor] = []
    private var sampleCount = 0

    var startTime: TimeInterval? { anchors.first?.time }
    var endTime: TimeInterval? { anchors.last.map { $0.time + offset - $0.offset } }

    private var offset: TimeInterval {
        Double(sampleCount) / AudioSampleConverter.speechSampleRate
    }

    mutating func append(sampleCount: Int, startTime: TimeInterval) {
        guard sampleCount > 0 else { return }
        if let endTime {
            if startTime - endTime > 0.05 {
                anchors.append(Anchor(offset: offset, time: startTime))
            }
        } else {
            anchors.append(Anchor(offset: 0, time: startTime))
        }
        self.sampleCount += sampleCount
    }

    func map(start: TimeInterval, end: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        guard !anchors.isEmpty else { return nil }
        var lower = 0
        var upper = anchors.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if anchors[middle].offset <= start {
                lower = middle
            } else {
                upper = middle
            }
        }
        let anchor = anchors[lower]
        // A single token cannot span a hole in the source audio.
        let limit = upper < anchors.count ? anchors[upper].offset : offset
        return (anchor.time + min(start, limit) - anchor.offset,
                anchor.time + min(end, limit) - anchor.offset)
    }
}
