#if canImport(Testing)
import Foundation
import Testing
@testable import ProsodyCore

@Test("duration formatting")
func durationFormatting() {
    #expect(ProsodyFormatters.duration(0) == "00:00")
    #expect(ProsodyFormatters.duration(3723) == "01:02:03")
    #expect(ProsodyFormatters.duration(-4) == "00:00")
}

@Test("file name sanitizing")
func fileNameSanitizing() {
    #expect(FileNameSanitizer.sanitize("  Lecture: Week 1  ") == "Lecture- Week 1")
    #expect(FileNameSanitizer.sanitize("\n\t") == "Recording")
}

@Test("capture mode sources")
func captureModeSources() {
    #expect(CaptureMode.system.sources == [.system])
    #expect(CaptureMode.microphone.sources == [.microphone])
    #expect(CaptureMode.both.sources == [.system, .microphone])
}

@Test("recording state flags")
func recordingStateFlags() {
    #expect(RecordingState.recording.isRecording)
    #expect(RecordingState.paused.isRecording)
    #expect(!RecordingState.idle.isRecording)
    #expect(RecordingState.finalizingTranscript.isBusy)
    #expect(!RecordingState.completed(UUID()).isBusy)
}
#else
// Apple Command Line Tools include SwiftPM but may omit the XCTest/Testing
// import modules. Keep the test target buildable there; Xcode runs the tests
// above when a test framework is available.
import ProsodyCore

enum ProsodyCoreBuildOnlyHarness {
    static let linked = ProsodyFormatters.duration(0) == "00:00"
}
#endif
