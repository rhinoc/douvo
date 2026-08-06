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

    func testExpiredAccountSessionCookieDoesNotProveLogin() throws {
        let params = DoubaoASRParams(
            httpCookies: [try makeCookie(name: "sessionid", expires: Date(timeIntervalSince1970: 100))],
            deviceId: "device-id",
            webId: "web-id"
        )

        XCTAssertFalse(params.hasRequiredAuthCookies(at: Date(timeIntervalSince1970: 200)))
    }

    func testDuplicateSessionCookieUsesLatestCookieExpiration() throws {
        let params = DoubaoASRParams(
            httpCookies: [
                try makeCookie(
                    name: "sessionid",
                    domain: ".doubao.com",
                    path: "/",
                    value: "expired-value",
                    expires: Date(timeIntervalSince1970: 100)
                ),
                try makeCookie(
                    name: "sessionid",
                    domain: "www.doubao.com",
                    path: "/account",
                    value: "session-value"
                )
            ],
            deviceId: "device-id",
            webId: "web-id"
        )

        XCTAssertEqual(params.cookies["sessionid"], "session-value")
        XCTAssertNil(params.cookieExpiresAt["sessionid"])
        XCTAssertTrue(params.hasRequiredAuthCookies(at: Date(timeIntervalSince1970: 200)))
    }

    func testCookieExpirationIsPersisted() throws {
        let expiration = Date(timeIntervalSince1970: 1_234_567)
        let params = DoubaoASRParams(
            httpCookies: [try makeCookie(name: "sessionid", expires: expiration)],
            deviceId: "device-id",
            webId: "web-id"
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(DoubaoASRParams.self, from: data)

        XCTAssertEqual(decoded.cookieExpiresAt["sessionid"], expiration)
    }

    func testLegacyParamsWithoutCookieExpirationRemainReadable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "cookies": ["sessionid": "test-value"],
            "deviceId": "device-id",
            "webId": "web-id"
        ])

        let params = try JSONDecoder().decode(DoubaoASRParams.self, from: data)

        XCTAssertTrue(params.hasRequiredAuthCookies)
        XCTAssertTrue(params.cookieExpiresAt.isEmpty)
    }

    private func makeCookie(
        name: String,
        domain: String = ".doubao.com",
        path: String = "/",
        value: String = "test-value",
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value
        ]
        if let expires {
            properties[.expires] = expires
        }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}
