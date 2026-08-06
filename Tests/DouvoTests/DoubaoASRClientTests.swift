import XCTest
@testable import Douvo

final class DoubaoASRClientTests: XCTestCase {
    func testTouristLimitIsRecognizedAsAuthenticationFailure() {
        XCTAssertTrue(
            DoubaoASRClient.isAuthLikeError(
                code: 710022013,
                message: "tourist reach limited"
            )
        )
    }

    func testUnrelatedServerErrorIsNotRecognizedAsAuthenticationFailure() {
        XCTAssertFalse(
            DoubaoASRClient.isAuthLikeError(
                code: 710020702,
                message: "server processing timeout"
            )
        )
    }
}
