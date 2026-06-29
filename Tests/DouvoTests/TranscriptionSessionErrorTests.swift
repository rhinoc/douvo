import XCTest
@testable import Douvo

final class TranscriptionSessionErrorTests: XCTestCase {
    func testLocalizedDescriptionSurvivesErrorBridge() {
        let sessionError = TranscriptionSessionError(
            domain: "Douvo.Audio",
            code: 1,
            localizedDescription: "Audio unit failed"
        )

        let error: Error = sessionError

        XCTAssertEqual(error.localizedDescription, "Audio unit failed")
    }

    func testNSErrorDetailsArePreserved() {
        let source = NSError(
            domain: "AVAudioEngine",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Input device unavailable"]
        )

        let sessionError = TranscriptionSessionError(source)

        XCTAssertEqual(sessionError.domain, "AVAudioEngine")
        XCTAssertEqual(sessionError.code, 42)
        XCTAssertEqual(sessionError.localizedDescription, "Input device unavailable")
    }
}
