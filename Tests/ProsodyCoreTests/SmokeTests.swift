#if canImport(XCTest)
import XCTest
@testable import ProsodyCore

final class SmokeTests: XCTestCase {
    func testFilenameSanitizerProvidesFallback() {
        XCTAssertEqual(FileNameSanitizer.sanitize("   "), "Recording")
        XCTAssertFalse(FileNameSanitizer.sanitize("Lecture/1").contains("/"))
    }
}
#endif
