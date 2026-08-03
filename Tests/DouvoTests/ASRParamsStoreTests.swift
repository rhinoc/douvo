import Foundation
import XCTest
@testable import Douvo

final class ASRParamsStoreTests: XCTestCase {
    func testWeakBrowserStateCookiesDoNotProveLogin() throws {
        let params = DoubaoASRParams(
            httpCookies: [
                try makeCookie(name: "sid_guard"),
                try makeCookie(name: "multi_sids")
            ],
            deviceId: "device-id",
            webId: "web-id"
        )

        XCTAssertFalse(params.hasRequiredAuthCookies)
    }

    func testAccountSessionCookieProvesLogin() throws {
        let params = DoubaoASRParams(
            httpCookies: [try makeCookie(name: "sessionid")],
            deviceId: "device-id",
            webId: "web-id"
        )

        XCTAssertTrue(params.hasRequiredAuthCookies)
    }

    private func makeCookie(name: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".doubao.com",
            .path: "/",
            .name: name,
            .value: "test-value"
        ]))
    }
}
