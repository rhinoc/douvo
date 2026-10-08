import CommonCrypto
import Foundation
import XCTest
@testable import Douvo

final class ChatterflyFeatureTests: XCTestCase {
    func testEncryptWallRequestMatchesNativeTransportHeadersWithoutNetwork() async throws {
        RejectingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectingURLProtocol.self]
        let client = ChatterflyEncryptWallClient(urlSession: URLSession(configuration: configuration))
        let body = Data(#"{"code":"headless-test"}"#.utf8)

        do {
            _ = try await client.request(
                urlString: "https://passport.ime.yb.local/api/v1/auth/exchange",
                method: "POST",
                body: body
            )
            XCTFail("The test transport should reject the request")
        } catch {
            XCTAssertTrue(error is ChatterflyEncryptWallError)
        }

        let request = try XCTUnwrap(RejectingURLProtocol.request())
        let packet = try ChatterflyEncryptWallPacket.make(
            urlString: "https://passport.ime.yb.local/api/v1/auth/exchange",
            postData: body
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "Chatterfly/1.0.4.13386 (Mac OS X \(ProcessInfo.processInfo.operatingSystemVersionString))"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Language"),
            Locale.preferredLanguages.enumerated().map { index, language in
                "\(language);q=\(index == 0 ? "1" : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0.1, 1.0 - Double(index) * 0.1)))"
            }.joined(separator: ", ")
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Length"),
            String(packet.body.count)
        )
        let sCookie = try XCTUnwrap(request.value(forHTTPHeaderField: "S-COOKIE"))
        XCTAssertTrue(sCookie.contains("c=1.0.4.13386&e=mac"))
        if ChatterflyNativeIdentityStore.currentUserID() != nil {
            XCTAssertTrue(sCookie.contains("&w="))
        }
    }

    func testEncryptWallRequestAppliesNativeLoginContentType() async throws {
        RejectingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectingURLProtocol.self]
        let client = ChatterflyEncryptWallClient(urlSession: URLSession(configuration: configuration))

        do {
            _ = try await client.request(
                urlString: "https://passport.ime.yb.local/api/v1/auth/exchange",
                method: "POST",
                body: Data(#"{"code":"headless-test"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
            XCTFail("The test transport should reject the request")
        } catch {
            XCTAssertTrue(error is ChatterflyEncryptWallError)
        }

        let request = try XCTUnwrap(RejectingURLProtocol.request())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSCookieIncludesNativeUserIDWhenAvailable() {
        XCTAssertEqual(
            ChatterflySCookie.make(
                inputMethodVersion: "1.0.4.13386",
                userID: "native-user",
                qimei36: "qimei"
            ),
            "c=1.0.4.13386&e=mac&w=native-user&qi=qimei"
        )
    }

    func testSCookie2MatchesNativeSpeechFormat() {
        XCTAssertEqual(
            ChatterflySCookie.make2(
                inputMethodVersion: "1.0.4.13386",
                userID: "native-user",
                sgid: "",
                qimei36: "qimei"
            ),
            "a=2&b=SogouInput&c=1.0.4.13386&e=mac&w=native-user&sgid=&qi=qimei"
        )
    }

    func testNativeIdentityDecryptsAccsArchive() throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: ["gYBLoginInfoUserId": "native-user"],
            requiringSecureCoding: false
        )
        let encrypted = try ChatterflyCrypto.aes(
            archive,
            key: Data("vc8v7vghw7v278vn2v8239vh29vh890m".utf8),
            iv: Data("aqkeezgxijvlm2op".utf8),
            operation: CCOperation(kCCEncrypt)
        ).base64EncodedData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("douvo-chatterfly-accs-\(UUID().uuidString).dat")
        try encrypted.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ChatterflyNativeIdentityStore.currentUserID(at: url), "native-user")
    }

    func testASRConfigurationMaterialUsesNativeRSABlockSize() throws {
        let material = try ChatterflyCrypto.encryptASRConfiguration(Data("{}".utf8))
        XCTAssertEqual(material.encryptedKey.count, 512)
        XCTAssertEqual(material.encodedIV.count, 24)
        XCTAssertEqual(Data(base64Encoded: material.encodedIV)?.count, 16)
        XCTAssertEqual(Data(base64Encoded: material.encryptedConfiguration)?.count, 16)
    }

    func testChatterflySpeechContextsOmitEmptyNativeIdentifiers() throws {
        let configuration = ChatterflyASRClient.nativeConfiguration(speechTerms: ["douvo"])
        let config = try XCTUnwrap(configuration["config"] as? [String: Any])
        let contexts = try XCTUnwrap(config["speech_contexts"] as? [[String: Any]])
        let context = try XCTUnwrap(contexts.first)
        let instants = try XCTUnwrap(context["instants"] as? [String: Any])

        XCTAssertNil(context["url"])
        XCTAssertNil(context["contact_id"])
        XCTAssertEqual(instants["phrases"] as? [String], ["douvo"])
        let emptyConfiguration = ChatterflyASRClient.nativeConfiguration(speechTerms: [])
        let emptyConfig = emptyConfiguration["config"] as? [String: Any]
        let emptyContexts = emptyConfig?["speech_contexts"] as? [[String: Any]]
        XCTAssertEqual(emptyContexts?.count, 0)
    }

    func testChatterflyPassportExpiryIsAuthenticationFailure() {
        XCTAssertTrue(ChatterflyASRClient.isAuthenticationFailureCode(40103))
        XCTAssertTrue(ChatterflyASRClient.isAuthenticationFailureCode(401))
        XCTAssertTrue(ChatterflyASRClient.isAuthenticationFailureCode(403))
        XCTAssertFalse(ChatterflyASRClient.isAuthenticationFailureCode(3))
    }

    func testEncryptWallPacketUsesGatewayFieldsAndSeparateRsaKey() throws {
        let packet = try ChatterflyEncryptWallPacket.make(
            urlString: "https://passport.ime.yb.local/api/v1/auth/exchange?source=web",
            postData: Data(#"{"code":"login-code"}"#.utf8)
        )
        let fields = Dictionary(uniqueKeysWithValues: String(decoding: packet.body, as: UTF8.self)
            .split(separator: "&", maxSplits: 5)
            .compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            })

        XCTAssertEqual(Set(fields.keys), Set(["u", "g", "p", "k", "v"]))
        XCTAssertEqual(packet.aesKey.count, 32)
        XCTAssertEqual(packet.aesIV.count, 16)
        XCTAssertEqual(fields["k"]?.count, 172)
        XCTAssertEqual(fields["v"]?.count, 172)
    }

    func testChatterflyLoginBridgeParsesTokenPayload() throws {
        let body = Data(#"{"param":"{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"uid\":\"user-1\"}"}"#.utf8)
        let token = ChatterflyAuthBridgeParser.token(bodyData: body, bodyString: nil)

        XCTAssertEqual(token?.accessToken, "access")
        XCTAssertEqual(token?.refreshToken, "refresh")
        XCTAssertEqual(token?.userID, "user-1")
        XCTAssertTrue(token?.isUsable == true)
    }

    func testChatterflyUserInfoRequestUsesNativeAuthorizationHeader() async throws {
        RejectingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectingURLProtocol.self]
        let client = ChatterflyEncryptWallClient(urlSession: URLSession(configuration: configuration))

        do {
            _ = try await client.request(
                urlString: ChatterflyEncryptWallPacket.userInfoURL,
                method: "POST",
                body: nil,
                headers: ["Authorization": "Bearer access-token"]
            )
            XCTFail("The test transport should reject the request")
        } catch {
            XCTAssertTrue(error is ChatterflyEncryptWallError)
        }

        let request = try XCTUnwrap(RejectingURLProtocol.request())
        XCTAssertEqual(request.url, ChatterflyEncryptWallPacket.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertNil(request.httpBody)
    }

    func testChatterflyUserInfoResponseRequiresSuccessfulCodeAndUserID() throws {
        let response = Data(#"{"code":0,"data":{"user_id":"user-1","nickname":"Ryan"}}"#.utf8)
        let parsed = try ChatterflyEncryptWallClient.parseUserInfoResponse(response)

        XCTAssertEqual(parsed.userID, "user-1")
        XCTAssertEqual(parsed.payload["nickname"] as? String, "Ryan")
        XCTAssertThrowsError(
            try ChatterflyEncryptWallClient.parseUserInfoResponse(
                Data(#"{"code":10001,"data":{"user_id":"user-1"}}"#.utf8)
            )
        )
    }

    func testChatterflyAuthTokenAttachesUserInfoIdentity() {
        let token = ChatterflyAuthToken(
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "Bearer",
            userID: nil,
            expiresAt: nil
        )

        XCTAssertEqual(token.withUserID("user-1").userID, "user-1")
        XCTAssertEqual(token.withUserID("user-1").accessToken, "access")
    }

    func testChatterflyBridgeReadsCallbackFromEnvelope() {
        let body = Data(#"{"param":{"url":"https://example.com/api","method":"POST"},"callback":"sg_callback"}"#.utf8)

        XCTAssertEqual(
            ChatterflyAuthBridgeParser.parameter(bodyData: body, bodyString: nil)?["url"] as? String,
            "https://example.com/api"
        )
        XCTAssertEqual(
            ChatterflyAuthBridgeParser.callback(bodyData: body, bodyString: nil),
            "sg_callback"
        )
    }

    func testChatterflyBridgeRepliesWithJSONObjectNotJSONString() throws {
        let script = try XCTUnwrap(
            ChatterflyJavaScriptCallback.script(
                callback: "sg_callback",
                json: #"{"code":0,"data":{"access_token":"redacted"}}"#
            )
        )

        XCTAssertEqual(
            script,
            #"window["sg_callback"]({"code":0,"data":{"access_token":"redacted"}});"#
        )
        XCTAssertFalse(script.contains(#"\"{\"code\""#))
    }
}

private final class RejectingURLProtocol: URLProtocol {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var capturedRequest: URLRequest?
    }

    private static let state = State()

    static func reset() {
        state.lock.lock()
        state.capturedRequest = nil
        state.lock.unlock()
    }

    static func request() -> URLRequest? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.capturedRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.capturedRequest = request
        Self.state.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
