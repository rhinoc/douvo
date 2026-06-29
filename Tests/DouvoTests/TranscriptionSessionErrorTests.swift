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

    func testNSErrorMetadataIsPreservedForDiagnostics() {
        let source = NSError(
            domain: "Douvo.AndroidASR",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "service discovery failure",
                TranscriptionErrorMetadata.userInfoKey: [
                    "android_request_id": "request-1",
                    "android_response_message_type": "SessionFailed"
                ]
            ]
        )

        let sessionError = TranscriptionSessionError(source)

        XCTAssertEqual(sessionError.metadata["android_request_id"], "request-1")
        XCTAssertEqual(sessionError.metadata["android_response_message_type"], "SessionFailed")
    }
}
