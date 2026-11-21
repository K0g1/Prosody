#if canImport(XCTest)
import Combine
import Foundation
import XCTest
@testable import ProsodyCore

final class TranscriptTimelineTests: XCTestCase {
    func testTimelineUsesDeterministicOverlapGapAndBoundaryRules() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let overlapID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let equalStartShortID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let equalStartLongID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

        let timeline = TranscriptTimeline(segments: [
            segment(id: equalStartLongID, start: 20, end: 24, text: "equal-start long"),
            segment(id: laterID, start: 12, end: 15, text: "later"),
            segment(id: overlapID, start: 2, end: 4, text: "overlap"),
            segment(id: firstID, start: 0, end: 10, text: "first"),
            segment(id: equalStartShortID, start: 20, end: 22, text: "equal-start short"),
            segment(start: 3, end: 4, text: "echo", echo: true)
        ])

        XCTAssertEqual(timeline.rows.map(\.id), [
            firstID, overlapID, laterID, equalStartShortID, equalStartLongID
        ])
        XCTAssertEqual(timeline.row(at: -1)?.id, firstID)
        XCTAssertEqual(timeline.row(at: 0)?.id, firstID)
        XCTAssertEqual(timeline.row(at: 1.99)?.id, firstID)
        XCTAssertEqual(timeline.row(at: 2)?.id, overlapID)
        XCTAssertEqual(timeline.row(at: 3)?.id, overlapID)
        XCTAssertEqual(timeline.row(at: 4.5)?.id, overlapID)
        XCTAssertEqual(timeline.row(at: 11.99)?.id, overlapID)
        XCTAssertEqual(timeline.row(at: 12)?.id, laterID)
        XCTAssertEqual(timeline.row(at: 15)?.id, laterID)
        XCTAssertEqual(timeline.row(at: 19.99)?.id, laterID)
        XCTAssertEqual(timeline.row(at: 20)?.id, equalStartLongID)
        XCTAssertEqual(timeline.row(at: 23)?.id, equalStartLongID)
        XCTAssertEqual(timeline.row(at: 25)?.id, equalStartLongID)
        XCTAssertNil(timeline.row(at: .nan))
    }

    func testTimelineHandlesTenThousandRowsAndBuildsBoundedDensity() {
        let segments = (0..<12_000).map { index in
            segment(
                start: Double(index) * 2,
                end: Double(index) * 2 + 1,
                text: "row \(index)"
            )
        }
        let timeline = TranscriptTimeline(segments: segments)

        XCTAssertEqual(timeline.rows.count, 12_000)
        XCTAssertEqual(timeline.density.bins.count, 240)
        XCTAssertEqual(timeline.density.bins.max(), 1)
        for index in stride(from: 0, to: 12_000, by: 137) {
            XCTAssertEqual(
                timeline.row(at: Double(index) * 2 + 0.5)?.chronologicalIndex,
                index
            )
            XCTAssertEqual(
                timeline.row(at: Double(index) * 2)?.chronologicalIndex,
                index
            )
            XCTAssertEqual(
                timeline.row(at: Double(index) * 2 + 1)?.chronologicalIndex,
                index
            )
        }
        XCTAssertEqual(timeline.row(at: -100)?.chronologicalIndex, 0)
        XCTAssertEqual(timeline.row(at: 1_000_000)?.chronologicalIndex, 11_999)
    }

    func testTimelineFiltersNonFiniteRowsAndDensityTracksSpeechEnd() {
        let timeline = TranscriptTimeline(segments: [
            segment(start: 0, end: 5, text: "speech"),
            segment(start: .nan, end: 7, text: "bad start"),
            segment(start: 8, end: .infinity, text: "bad end"),
            segment(start: 10, end: 12, text: "later speech")
        ])

        XCTAssertEqual(timeline.rows.map(\.text), ["speech", "later speech"])
        XCTAssertEqual(timeline.density.speechEnd, 12)
        XCTAssertEqual(timeline.density.bins.count, 240)

        let invalidRow = TranscriptTimelineRow(
            segment: segment(start: .nan, end: .nan, text: "invalid"),
            chronologicalIndex: 0
        )
        let invalidDensity = TranscriptTimelineDensity(rows: [invalidRow], binCount: 8)
        XCTAssertEqual(invalidDensity.speechEnd, 0)
        XCTAssertEqual(invalidDensity.bins, Array(repeating: 0, count: 8))
    }

    @MainActor
    func testReaderCacheRebuildsOncePerDocumentEditAndFiltersOncePerQuery() {
        let transcript = Transcript(segments: [
            segment(start: 0, end: 1, text: "needle one"),
            segment(start: 1, end: 2, text: "other"),
            segment(start: 2, end: 3, text: "needle two")
        ])
        let cache = TranscriptReaderCache(transcript: transcript)
        let initialRebuilds = cache.rebuildCount
        let initialRevision = cache.projectionRevision

        cache.update(transcript: transcript)
        XCTAssertEqual(cache.rebuildCount, initialRebuilds)
        XCTAssertEqual(cache.projectionRevision, initialRevision)

        cache.updateSearch("needle")
        XCTAssertEqual(cache.projection.rows.count, 2)
        XCTAssertEqual(cache.searchProjectionCount, 1)
        XCTAssertEqual(cache.projectionRevision, initialRevision + 1)
        cache.updateSearch("needle")
        XCTAssertEqual(cache.searchProjectionCount, 1)
        XCTAssertEqual(cache.projectionRevision, initialRevision + 1)

        var edited = transcript
        edited.segments[0].speakerName = "Lecturer"
        cache.update(transcript: edited)
        XCTAssertEqual(cache.rebuildCount, initialRebuilds + 1)
        XCTAssertEqual(cache.projectionRevision, initialRevision + 2)
        XCTAssertEqual(cache.projection.query, "needle")
        XCTAssertEqual(cache.projection.rows.count, 2)
    }

    @MainActor
    func testReaderCachePublishesOnceForDocumentEditWhileSearching() {
        let transcript = Transcript(segments: [
            segment(start: 0, end: 1, text: "needle one"),
            segment(start: 1, end: 2, text: "other")
        ])
        let cache = TranscriptReaderCache(transcript: transcript)
        cache.updateSearch("needle")
        var publications = 0
        let cancellable = cache.objectWillChange.sink { _ in publications += 1 }

        var edited = transcript
        edited.segments[0].speakerName = "Lecturer"
        cache.update(transcript: edited)

        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testFollowStatePublishesOnlyWhenTheRowChanges() {
        let timeline = TranscriptTimeline(segments: (0..<10).map { index in
            segment(start: Double(index) * 10, end: Double(index) * 10 + 5, text: "row \(index)")
        })
        var state = TranscriptFollowState()

        let first = state.update(time: 1, timeline: timeline)
        XCTAssertEqual(first?.rowID, timeline.rows[0].id)
        XCTAssertEqual(first?.requestID, 1)
        XCTAssertFalse(first?.shouldAnimate ?? true)

        for time in stride(from: 1.1, through: 9.9, by: 0.2) {
            XCTAssertNil(state.update(time: time, timeline: timeline))
        }

        let next = state.update(time: 10, timeline: timeline)
        XCTAssertEqual(next?.rowID, timeline.rows[1].id)
        XCTAssertEqual(next?.requestID, 2)
        XCTAssertTrue(next?.shouldAnimate ?? false)

        let jump = state.update(time: 90, timeline: timeline)
        XCTAssertEqual(jump?.rowID, timeline.rows[9].id)
        XCTAssertEqual(jump?.requestID, 3)
        XCTAssertFalse(jump?.shouldAnimate ?? true)

        state.reset()
        XCTAssertNotNil(state.update(time: 90, timeline: timeline))

        state.reset()
        _ = state.update(time: 0, timeline: timeline)
        let scrubDirective = state.update(time: 10, timeline: timeline, allowsAnimation: false)
        XCTAssertFalse(scrubDirective?.shouldAnimate ?? true)
    }

    func testFollowPolicyAllowsExplicitScrubButNotFilteredScrub() {
        XCTAssertTrue(TranscriptFollowPolicy.shouldFollow(
            autoFollow: false,
            isScrubbing: true,
            isSearchActive: false
        ))
        XCTAssertFalse(TranscriptFollowPolicy.shouldFollow(
            autoFollow: false,
            isScrubbing: true,
            isSearchActive: true
        ))
        XCTAssertFalse(TranscriptFollowPolicy.shouldFollow(
            autoFollow: false,
            isScrubbing: false,
            isSearchActive: false
        ))
    }

    @MainActor
    func testFinalScrubHighlightPersistsThroughTicksWhenFollowIsOff() async throws {
        let timeline = TranscriptTimeline(segments: [
            segment(start: 0, end: 1, text: "First"),
            segment(start: 1, end: 2, text: "Preview"),
            segment(start: 2, end: 3, text: "Committed"),
            segment(start: 3, end: 4, text: "Playing")
        ])
        let controller = TranscriptFollowController()
        controller.update(time: 0.5, timeline: timeline)
        controller.update(time: 1.5, timeline: timeline, minimumInterval: .milliseconds(100))
        controller.finishScrub(at: 2.5, timeline: timeline)
        let committed = try XCTUnwrap(controller.directive)
        XCTAssertEqual(committed.rowID, timeline.rows[2].id)
        XCTAssertFalse(committed.shouldAnimate)

        controller.updateFromPlayback(
            time: 3.5, timeline: timeline, autoFollow: false,
            isPlaying: true, isScrubbing: false, isSearchActive: false
        )
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.directive, committed)

        controller.suspend()
        XCTAssertNil(controller.directive)
    }

    func testFollowCoalescerKeepsTheLatestRapidDirective() {
        let start = ContinuousClock.now
        var coalescer = TranscriptFollowCoalescer(minimumInterval: .milliseconds(40))
        let first = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 0, requestID: 1, shouldAnimate: false
        )
        let second = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 1, requestID: 2, shouldAnimate: false
        )
        let third = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 2, requestID: 3, shouldAnimate: false
        )

        XCTAssertEqual(coalescer.accept(first, at: start)?.requestID, 1)
        XCTAssertNil(coalescer.accept(second, at: start.advanced(by: .milliseconds(10))))
        XCTAssertNil(coalescer.accept(third, at: start.advanced(by: .milliseconds(20))))
        XCTAssertEqual(
            coalescer.takePending(at: start.advanced(by: .milliseconds(40)))?.requestID,
            3
        )
    }

    func testFollowCoalescerUsesTheCurrentRefreshWindow() {
        let start = ContinuousClock.now
        var coalescer = TranscriptFollowCoalescer(minimumInterval: .milliseconds(100))
        let first = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 0, requestID: 1, shouldAnimate: false
        )
        let second = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 1, requestID: 2, shouldAnimate: false
        )
        let third = TranscriptFollowDirective(
            rowID: UUID(), rowIndex: 2, requestID: 3, shouldAnimate: false
        )

        XCTAssertEqual(coalescer.accept(first, at: start)?.requestID, 1)
        XCTAssertNil(coalescer.accept(second, at: start.advanced(by: .milliseconds(50))))
        coalescer.minimumInterval = .milliseconds(33)
        XCTAssertEqual(
            coalescer.accept(third, at: start.advanced(by: .milliseconds(70)))?.requestID,
            3
        )
    }

    func testAudioTimelineUsesCumulativeOffsetsAndBoundarySemantics() {
        let urls = [
            URL(fileURLWithPath: "/tmp/chunk-1.m4a"),
            URL(fileURLWithPath: "/tmp/chunk-2.m4a"),
            URL(fileURLWithPath: "/tmp/chunk-3.m4a")
        ]
        let timeline = SessionAudioTimeline(urls: urls, durations: [10, 5, 20])

        XCTAssertEqual(timeline.chunks.map(\.start), [0, 10, 15])
        XCTAssertEqual(timeline.duration, 35)
        XCTAssertEqual(timeline.chunkIndex(containing: -1), 0)
        XCTAssertEqual(timeline.chunkIndex(containing: 0), 0)
        XCTAssertEqual(timeline.chunkIndex(containing: 9.999), 0)
        XCTAssertEqual(timeline.chunkIndex(containing: 10), 1)
        XCTAssertEqual(timeline.chunkIndex(containing: 14.999), 1)
        XCTAssertEqual(timeline.chunkIndex(containing: 15), 2)
        XCTAssertEqual(timeline.chunkIndex(containing: 35), 2)
        XCTAssertNil(timeline.chunkIndex(containing: .nan))
        XCTAssertEqual(timeline.localTime(for: 12, chunkIndex: 1), 2, accuracy: 0.0001)
        XCTAssertEqual(timeline.globalTime(chunkIndex: 2, localTime: 3), 18, accuracy: 0.0001)
        XCTAssertEqual(timeline.localTime(for: .nan, chunkIndex: 1), 0)
        XCTAssertEqual(timeline.globalTime(chunkIndex: 2, localTime: .infinity), 0)
    }

    func testNumberedAudioSequenceRequiresContiguousSiblings() {
        let numbered = [1, 2, 3].map {
            URL(fileURLWithPath: String(format: "/tmp/%06d.m4a", $0))
        }
        XCTAssertTrue(SessionAudioTimeline.hasContiguousNumberedChunks(numbered))
        XCTAssertFalse(SessionAudioTimeline.hasContiguousNumberedChunks([numbered[0], numbered[2]]))
        XCTAssertFalse(SessionAudioTimeline.hasContiguousNumberedChunks([numbered[1], numbered[2]]))
        XCTAssertFalse(SessionAudioTimeline.hasContiguousNumberedChunks([
            numbered[0],
            numbered[2],
            URL(fileURLWithPath: "/tmp/extra.m4a")
        ]))
        XCTAssertFalse(SessionAudioTimeline.hasContiguousNumberedChunks([
            numbered[0],
            numbered[1],
            URL(fileURLWithPath: "/tmp/extra.m4a")
        ]))
        XCTAssertTrue(SessionAudioTimeline.hasContiguousNumberedChunks([numbered[2]]))
        XCTAssertFalse(SessionAudioTimeline.hasContiguousNumberedChunks([
            URL(fileURLWithPath: "/tmp/session/audio/system/000002.m4a")
        ]))
        XCTAssertTrue(SessionAudioTimeline.hasContiguousNumberedChunks([
            URL(fileURLWithPath: "/tmp/session/audio/system/000001.m4a")
        ]))
        XCTAssertTrue(SessionAudioTimeline.hasContiguousNumberedChunks([
            URL(fileURLWithPath: "/tmp/system.caf"),
            URL(fileURLWithPath: "/tmp/microphone.caf")
        ]))
    }

    private func segment(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        echo: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            source: .system,
            start: start,
            end: end,
            text: text,
            isFinal: true,
            isEchoDuplicate: echo
        )
    }
}
#endif
