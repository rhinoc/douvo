import Foundation
import XCTest
@testable import Douvo

final class BageshuoASRClientTests: XCTestCase {
    func testSignerUsesSortedNonEmptyParametersAndLowercaseMD5() {
        let context = BageshuoSigningContext(
            product: "dict",
            appVersion: "1.0.30",
            client: "mac",
            mid: "1",
            vendor: "web",
            screen: "1",
            model: "1",
            imei: "1",
            network: "wifi",
            keyfrom: "pc",
            abtest: "",
            yduuid: "test-device"
        )

        let signed = BageshuoSigner.signedParameters(
            context: context,
            nowMilliseconds: 1_700_000_000_000,
            secret: "test-secret"
        )

        XCTAssertEqual(signed["pointParam"], "appVersion,client,imei,keyfrom,keyid,mid,model,mysticTime,network,product,screen,vendor,yduuid,key")
        XCTAssertEqual(signed["sign"], "7486174c7298f29200be5372ec8721bd")
        XCTAssertNil(signed["abtest"])
    }

    func testStartFrameCarriesRealtimeAudioContract() throws {
        let frame = BageshuoASRClient.controlFrame(
            type: "utterance.start",
            requestID: "request-1",
            utteranceID: "utterance-1",
            payload: [
                "operation": "POLISH",
                "sourceLanguage": "AUTO",
                "targetLanguage": NSNull(),
                "selectedText": NSNull(),
                "audio": [
                    "encoding": "PCM_S16LE",
                    "sampleRateHz": 16_000,
                    "channels": 1
                ]
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "utterance.start")
        XCTAssertEqual(object["requestId"] as? String, "request-1")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["operation"] as? String, "POLISH")
        let audio = try XCTUnwrap(payload["audio"] as? [String: Any])
        XCTAssertEqual(audio["encoding"] as? String, "PCM_S16LE")
        XCTAssertEqual(audio["sampleRateHz"] as? Int, 16_000)
        XCTAssertEqual(audio["channels"] as? Int, 1)
    }

    func testEventParserExtractsStreamingAndGenerationResults() throws {
        let partial = try XCTUnwrap(BageshuoASRClient.parseEvent("""
        {"v":1,"type":"transcript.partial","eventId":"e1","timestamp":"1","payload":{"revision":2,"fullText":"实时"}}
        """))
        XCTAssertEqual(partial.type, "transcript.partial")
        XCTAssertEqual(partial.payload["fullText"], "实时")
        XCTAssertEqual(partial.payload["revision"], "2")

        let completed = try XCTUnwrap(BageshuoASRClient.parseEvent("""
        {"v":1,"type":"generation.completed","eventId":"e2","timestamp":"2","payload":{"resultText":"最终结果","generationId":"g1","operation":"POLISH"}}
        """))
        XCTAssertEqual(completed.payload["resultText"], "最终结果")
        XCTAssertEqual(completed.payload["generationId"], "g1")
    }

    func testAuthenticationFailuresAreClassifiedWithoutTreatingServerTimeoutAsAuth() {
        XCTAssertTrue(BageshuoASRClient.isAuthLikeError(code: 401, message: "request failed"))
        XCTAssertTrue(BageshuoASRClient.isAuthLikeError(code: 0, message: "login is required"))
        XCTAssertFalse(BageshuoASRClient.isAuthLikeError(code: 403, message: "SIGNATURE_INVALID"))
        XCTAssertFalse(BageshuoASRClient.isAuthLikeError(code: 500, message: "server processing timeout"))
    }

    func testAPIErrorParserExtractsCodeAndMessageWithoutRequiringTicketShape() throws {
        let summary = BageshuoASRClient.apiError(from: Data("{\"errorCode\":\"403\",\"message\":\"signature rejected\"}".utf8))
        XCTAssertEqual(summary.code, 403)
        XCTAssertEqual(summary.message, "signature rejected")
    }

    func testInstalledAppLoginStateMapsToRealtimeCookieSet() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "deviceId": "installed-device-id",
            "login": [
                "loggedIn": true,
                "userId": "user-id",
                "pc": "pc-value",
                "pci": "pci-value",
                "tp": "tp-value"
            ]
        ])

        let params = try XCTUnwrap(BageshuoInstalledAppCredentialImporter.params(from: data))
        XCTAssertEqual(params.cookies["DICT-PC"], "pci-value")
        XCTAssertEqual(params.cookies["cf7"], "pc-value")
        XCTAssertEqual(params.cookies["umurscookie"], "tp-value")
        XCTAssertEqual(params.typelessUser, "user-id")
        XCTAssertEqual(params.deviceID, "installed-device-id")
    }

    func testInstalledAppCredentialImporterRejectsSignedOutOrIncompleteState() throws {
        let signedOut = try JSONSerialization.data(withJSONObject: [
            "login": [
                "loggedIn": false,
                "userId": "user-id",
                "pc": "pc-value",
                "pci": "pci-value",
                "tp": "tp-value"
            ]
        ])
        let incomplete = try JSONSerialization.data(withJSONObject: [
            "login": [
                "loggedIn": true,
                "userId": "user-id",
                "pc": "pc-value",
                "pci": "",
                "tp": "tp-value"
            ]
        ])

        XCTAssertNil(BageshuoInstalledAppCredentialImporter.params(from: signedOut))
        XCTAssertNil(BageshuoInstalledAppCredentialImporter.params(from: incomplete))
    }

    func testBageShuoAuthRequiresIdentityAndKnownAuthCookie() throws {
        let anonymous = BageshuoASRParams(
            cookies: ["P_INFO": "profile"],
            typelessUser: "user-id"
        )
        let authenticated = BageshuoASRParams(
            cookies: ["DICT_UT": "session"],
            typelessUser: "user-id"
        )

        XCTAssertFalse(anonymous.hasRequiredAuthCookies)
        XCTAssertTrue(authenticated.hasRequiredAuthCookies)
    }

    func testInstalledAppImportDoesNotResurrectCredentialsAfterLogout() {
        let installedParams = BageshuoASRParams(
            cookies: ["DICT_UT": "installed-session"],
            typelessUser: "user-id"
        )
        let changedParams = BageshuoASRParams(
            cookies: ["DICT_UT": "new-installed-session"],
            typelessUser: "user-id"
        )

        XCTAssertTrue(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: false,
                storedParams: nil,
                installedParams: installedParams
            )
        )
        XCTAssertFalse(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: nil,
                installedParams: installedParams
            )
        )
        XCTAssertFalse(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: installedParams,
                installedParams: installedParams
            )
        )
        XCTAssertTrue(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: installedParams,
                installedParams: changedParams,
                lastImportedFingerprint: "old-installed-fingerprint",
                installedFingerprint: "new-installed-fingerprint"
            )
        )
    }

    func testInstalledAppChangesDoNotReplaceExplicitDouvoLogin() {
        let douvoParams = BageshuoASRParams(
            cookies: ["DICT_UT": "douvo-session"],
            typelessUser: "user-id"
        )
        let installedParams = BageshuoASRParams(
            cookies: ["DICT_UT": "installed-session"],
            typelessUser: "user-id"
        )

        XCTAssertFalse(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: douvoParams,
                installedParams: installedParams
            )
        )
        XCTAssertFalse(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: douvoParams,
                installedParams: installedParams,
                credentialSource: .douvoWebView,
                lastImportedFingerprint: "old-installed-fingerprint",
                installedFingerprint: "new-installed-fingerprint"
            )
        )
    }

    func testInstalledAppUpdatesAreAcceptedForImportedCredentials() {
        let installedParams = BageshuoASRParams(
            cookies: ["DICT_UT": "installed-session"],
            typelessUser: "user-id"
        )

        XCTAssertTrue(
            BageshuoASRParamsStore.shouldImportInstalledParams(
                completedInitialImport: true,
                storedParams: installedParams,
                installedParams: installedParams,
                credentialSource: .installedApp,
                lastImportedFingerprint: "same-installed-fingerprint",
                installedFingerprint: "new-installed-fingerprint"
            )
        )
    }

    func testInstalledAppSessionRehydrateFormMatchesOriginalClientFields() throws {
        let body = try XCTUnwrap(
            BageshuoInstalledAppCredentialImporter.sessionRehydrateForm(
                accountSessionToken: "session token"
            )
        )
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            "cf=7&DICT-PC=session%20token&um=true&product=DICT"
        )
    }

    func testInstalledAppSessionRehydrateResponseParsesLoginFlag() {
        XCTAssertEqual(
            BageshuoInstalledAppCredentialImporter.sessionRehydrateLoginValue(
                from: Data(#"{"login":true}"#.utf8)
            ),
            true
        )
        XCTAssertEqual(
            BageshuoInstalledAppCredentialImporter.sessionRehydrateLoginValue(
                from: Data(#"{"data":{"login":false}}"#.utf8)
            ),
            false
        )
        XCTAssertNil(
            BageshuoInstalledAppCredentialImporter.sessionRehydrateLoginValue(
                from: Data(#"{"message":"invalid"}"#.utf8)
            )
        )
    }

    func testHotWordListRequestUsesSignedQueryAndAccountHeaders() throws {
        let params = BageshuoASRParams(
            cookies: ["DICT_UT": "session", "P_INFO": "profile"],
            typelessUser: "user-id",
            deviceID: "device-id"
        )
        let request = BageshuoHotWordsClient.makeListRequest(
            params: params,
            page: 2,
            limit: 100,
            keyword: "Swift 网络",
            nowMilliseconds: 1_700_000_000_000
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(query["page"], "2")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["keyword"], "Swift 网络")
        XCTAssertNotNil(query["sign"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "DICT_UT=session; P_INFO=profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Typeless-User"), "user-id")
    }

    func testHotWordCreateRequestUsesSignedJSONPostAndAccountHeaders() throws {
        let params = BageshuoASRParams(
            cookies: ["DICT_UT": "session"],
            typelessUser: "user-id",
            deviceID: "device-id"
        )
        let request = try BageshuoHotWordsClient.makeMutationRequest(
            params: params,
            method: "POST",
            body: ["word": "端侧模型"],
            nowMilliseconds: 1_700_000_000_000
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(payload["word"] as? String, "端侧模型")
        XCTAssertNotNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sign" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "DICT_UT=session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Typeless-User"), "user-id")
    }

    func testHotWordMutationResponseAcceptsEmptyAndSuccessPayloads() throws {
        XCTAssertNoThrow(try BageshuoHotWordsClient.parseMutationResponse(from: Data()))
        XCTAssertNoThrow(try BageshuoHotWordsClient.parseMutationResponse(from: Data(#"{"code":0,"data":null}"#.utf8)))
        XCTAssertThrowsError(try BageshuoHotWordsClient.parseMutationResponse(from: Data(#"{"code":403,"msg":"请求签名无效"}"#.utf8)))
    }

    func testHotWordResponseParsesServerDataArray() throws {
        let data = Data(#"{"code":200,"msg":"ok","data":[{"hotWordId":"w1","word":"SwiftUI"},{"hotWordId":"w2","word":"端侧模型"}]}"#.utf8)

        XCTAssertEqual(
            try BageshuoHotWordsClient.parsePage(from: data),
            [
                BageshuoHotWord(id: "w1", word: "SwiftUI"),
                BageshuoHotWord(id: "w2", word: "端侧模型")
            ]
        )
    }

    func testHotWordResponseRejectsAPIErrorAndMalformedItems() {
        XCTAssertThrowsError(
            try BageshuoHotWordsClient.parsePage(
                from: Data(#"{"code":403,"msg":"请求签名无效","data":null}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? BageshuoHotWordsError,
                .apiFailure(code: 403, message: "请求签名无效")
            )
        }
        XCTAssertThrowsError(
            try BageshuoHotWordsClient.parsePage(
                from: Data(#"{"code":200,"data":[{"hotWordId":"w1"}]}"#.utf8)
            )
        )
    }

    func testBageVocabularyMergesWithManualTermsWithoutDuplicates() {
        XCTAssertEqual(
            BageshuoVocabularyStore.mergedVocabulary(
                manualVocabulary: "SwiftUI\n自己的词条",
                importedWords: ["端侧模型", "swiftui", "自己的词条"]
            ),
            "SwiftUI\n自己的词条\n端侧模型"
        )
    }
}
