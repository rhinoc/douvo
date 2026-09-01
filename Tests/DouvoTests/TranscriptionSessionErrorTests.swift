import XCTest
@testable import Douvo

final class TranscriptionSessionErrorTests: XCTestCase {
    @MainActor
    func testAndroidServerErrorPreservesItsActualCause() {
        let previousLanguage = AppLanguageStore.selected
        AppLanguageStore.selected = .english
        defer { AppLanguageStore.selected = previousLanguage }
        let error = TranscriptionSessionError(
            domain: "Douvo.AndroidASR",
            code: 3,
            localizedDescription: "service discovery failure"
        )

        XCTAssertEqual(
            TranscriptionManager.userFacingASRErrorMessage(error),
            "Android recognition failed: service discovery failure"
        )
    }

    @MainActor
    func testAndroidConcurrencyQuotaUsesExplicitQuotaMessage() {
        let previousLanguage = AppLanguageStore.selected
        AppLanguageStore.selected = .simplifiedChinese
        defer { AppLanguageStore.selected = previousLanguage }
        let error = TranscriptionSessionError(
            domain: "Douvo.AndroidASR",
            code: 3,
            localizedDescription: "concurrency quota exceeded: value:5"
        )

        XCTAssertEqual(
            TranscriptionManager.userFacingASRErrorMessage(error),
            "Android 服务并发配额已满"
        )
    }

    @MainActor
    func testNetworkTransportErrorStillUsesNetworkMessage() {
        let previousLanguage = AppLanguageStore.selected
        AppLanguageStore.selected = .english
        defer { AppLanguageStore.selected = previousLanguage }
        let error = TranscriptionSessionError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            localizedDescription: "The Internet connection appears to be offline."
        )

        XCTAssertEqual(
            TranscriptionManager.userFacingASRErrorMessage(error),
            "Network connection interrupted."
        )
    }

    @MainActor
    func testMissingASRErrorDoesNotClaimNetworkFailure() {
        let previousLanguage = AppLanguageStore.selected
        AppLanguageStore.selected = .english
        defer { AppLanguageStore.selected = previousLanguage }

        XCTAssertEqual(
            TranscriptionManager.userFacingASRErrorMessage(nil),
            "Recognition failed."
        )
    }

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

    func testAndroidConcurrencyQuotaErrorsAreRecognized() {
        XCTAssertTrue(AndroidASRErrorClassifier.isConcurrencyQuotaExceeded(
            statusCode: AndroidASRErrorClassifier.concurrencyQuotaStatusCode,
            message: "unrelated server text"
        ))
        XCTAssertTrue(AndroidASRErrorClassifier.isConcurrencyQuotaExceeded(
            "concurrency quota exceeded: key:example,value:5"
        ))
        XCTAssertTrue(AndroidASRErrorClassifier.isConcurrencyQuotaExceeded("ExceedConcurrentQuota"))
        XCTAssertFalse(AndroidASRErrorClassifier.isConcurrencyQuotaExceeded("authentication failed"))
    }

    func testAndroidSessionAuthMissingIdentityIsEligibleForAppKeyRotation() {
        XCTAssertTrue(
            AndroidASRErrorClassifier.isAppKeyRotationCandidate(
                statusCode: AndroidASRErrorClassifier.sessionAuthMissingIdentityStatusCode,
                message: "session auth, userID or appID is empty"
            )
        )
        XCTAssertFalse(
            AndroidASRErrorClassifier.isAppKeyRotationCandidate(
                statusCode: 40_200_002,
                message: "authentication failed"
            )
        )
    }

    func testAndroidCredentialRequestsDoNotReuseCookies() {
        let configuration = DoubaoAndroidCredentialStore.makeURLSessionConfiguration()

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
    }
}
