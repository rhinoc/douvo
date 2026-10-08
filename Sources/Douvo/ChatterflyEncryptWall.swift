import CommonCrypto
import Foundation
import Security
import zlib

enum ChatterflyEncryptWallError: LocalizedError {
    case invalidURL
    case invalidPayload
    case compressionFailed(Int32)
    case decompressionFailed(Int32)
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Chatterfly EncryptWall received an invalid URL"
        case .invalidPayload:
            return "Chatterfly EncryptWall could not encode the request"
        case let .compressionFailed(status):
            return "Chatterfly EncryptWall compression failed (status=\(status))"
        case let .decompressionFailed(status):
            return "Chatterfly EncryptWall decompression failed (status=\(status))"
        case .invalidResponse:
            return "Chatterfly EncryptWall returned an invalid response"
        case let .httpStatus(status):
            return "Chatterfly EncryptWall returned HTTP \(status)"
        }
    }
}

struct ChatterflyEncryptWallPacket {
    static let endpoint = URL(string: "https://sec.chatterfly.tencent.com/q")!
    static let userInfoURL = "https://passport.ime.yb.local/api/v1/user/userinfo"

    // Extracted from DataEncryptor.getRsaPublicKey in the installed Chatterfly build.
    static let rsaPublicKeyBase64 =
        "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDXDX6m3PV844sOhM+/WFkh2UBYcswDX6e3JdmvAlyje4I5BMX+pjwXkni+ak6H4/Qk6pMN78CfvfxG7bdoQlLMZgBcs/TshPiglN3Gh/hnZXoeFA7litmMxd5BNFNfU1HMV6zbtAeoSOddEM2uLQ9puFSYUyd4j2ul6Wp14Efp8QIDAQAB"

    let body: Data
    let aesKey: Data
    let aesIV: Data

    static func make(urlString: String, postData: Data?) throws -> ChatterflyEncryptWallPacket {
        guard let separator = urlString.firstIndex(of: "?") else {
            return try make(baseURL: urlString, query: nil, postData: postData)
        }

        let baseURL = String(urlString[..<separator])
        let queryStart = urlString.index(after: separator)
        let query = String(urlString[queryStart...])
        return try make(baseURL: baseURL, query: query.isEmpty ? nil : query, postData: postData)
    }

    private static func make(baseURL: String, query: String?, postData: Data?) throws -> ChatterflyEncryptWallPacket {
        guard !baseURL.isEmpty, baseURL.data(using: .utf8) != nil else {
            throw ChatterflyEncryptWallError.invalidURL
        }

        let aesKey = try randomData(count: 32)
        let aesIV = try randomData(count: 16)
        var fields: [String] = []

        let baseURLFrame = try encryptedField(Data(baseURL.utf8), key: aesKey, iv: aesIV)
        fields.append("u=\(baseURLFrame)")
        if let query {
            fields.append("g=\(try encryptedField(Data(query.utf8), key: aesKey, iv: aesIV))")
        }
        if let postData, !postData.isEmpty {
            fields.append("p=\(try encryptedField(postData, key: aesKey, iv: aesIV))")
        }
        fields.append("k=\(try ChatterflyCrypto.rsaEncrypt(aesKey, publicKeyBase64: rsaPublicKeyBase64).base64EncodedString())")
        fields.append("v=\(try ChatterflyCrypto.rsaEncrypt(aesIV, publicKeyBase64: rsaPublicKeyBase64).base64EncodedString())")

        guard let body = fields.joined(separator: "&").data(using: .utf8) else {
            throw ChatterflyEncryptWallError.invalidPayload
        }
        return ChatterflyEncryptWallPacket(body: body, aesKey: aesKey, aesIV: aesIV)
    }

    static func decryptResponse(_ responseData: Data, aesKey: Data, aesIV: Data) throws -> Data {
        guard let responseString = String(data: responseData, encoding: .utf8),
              let encrypted = Data(base64Encoded: responseString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatterflyEncryptWallError.invalidResponse
        }

        let decrypted = try ChatterflyCrypto.aes(
            encrypted,
            key: aesKey,
            iv: aesIV,
            operation: CCOperation(kCCDecrypt)
        )

        // Native Chatterfly always removes the four-byte envelope before raw inflate.
        guard decrypted.count > 4 else {
            throw ChatterflyEncryptWallError.invalidResponse
        }
        return try inflateRaw(Data(decrypted.dropFirst(4)))
    }

    private static func encryptedField(_ data: Data, key: Data, iv: Data) throws -> String {
        let compressed = try deflateRaw(data)
        let encrypted = try ChatterflyCrypto.aes(
            compressed,
            key: key,
            iv: iv,
            operation: CCOperation(kCCEncrypt)
        )
        return encrypted.base64EncodedString()
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ChatterflyCryptoError.randomFailure(status)
        }
        return data
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status: Int32 = ZLIB_VERSION.withCString { version in
            deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, version, Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Z_OK else {
            throw ChatterflyEncryptWallError.compressionFailed(status)
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let input = data
        input.withUnsafeBytes { inputBytes in
            stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(inputBytes.count)
            repeat {
                var chunk = [UInt8](repeating: 0, count: max(256, data.count + 64))
                status = chunk.withUnsafeMutableBytes { outputBytes in
                    stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBytes.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(produced))
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else {
            throw ChatterflyEncryptWallError.compressionFailed(status)
        }
        return output
    }

    private static func inflateRaw(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status: Int32 = ZLIB_VERSION.withCString { version in
            inflateInit2_(&stream, -15, version, Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Z_OK else {
            throw ChatterflyEncryptWallError.decompressionFailed(status)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let input = data
        input.withUnsafeBytes { inputBytes in
            stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(inputBytes.count)
            repeat {
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                status = chunk.withUnsafeMutableBytes { outputBytes in
                    stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBytes.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(produced))
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else {
            throw ChatterflyEncryptWallError.decompressionFailed(status)
        }
        return output
    }
}

final class ChatterflyEncryptWallClient: @unchecked Sendable {
    private let urlSession: URLSession

    private static let inputMethodVersion = "1.0.4.13386"
    private static let nativeUserAgent = "Chatterfly/\(inputMethodVersion) (Mac OS X \(ProcessInfo.processInfo.operatingSystemVersionString))"
    private static let deviceIDKey = "Douvo.Chatterfly.encryptWallDeviceID"
    private static let qimeiCachePrefix = "enc.v1:"
    private static let qimeiCacheKey = "keyQimei36Cache"
    private static let qimeiCacheSalt = "SGQimeiCache.v1.q36"

    private static var nativeAcceptLanguage: String {
        Locale.preferredLanguages.enumerated().map { index, language in
            let quality = index == 0 ? "1" : String(
                format: "%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                max(0.1, 1.0 - Double(index) * 0.1)
            )
            return "\(language);q=\(quality)"
        }.joined(separator: ", ")
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func request(
        urlString: String,
        method: String,
        body: Data?,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let targetURL = URL(string: urlString), targetURL.scheme != nil else {
            throw ChatterflyEncryptWallError.invalidURL
        }

        let packet = try ChatterflyEncryptWallPacket.make(urlString: urlString, postData: body)
        var request = URLRequest(url: ChatterflyEncryptWallPacket.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // AFHTTPRequestSerializer in Chatterfly adds these headers before the
        // login-specific headers are applied.
        request.setValue(Self.nativeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            Self.nativeAcceptLanguage,
            forHTTPHeaderField: "Accept-Language"
        )
        // SogouNetworking's native sendPostRequestByEW path uses its default
        // EncryptWall content type for the encrypted transport body.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(packet.body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if headers["S-COOKIE"] == nil {
            request.setValue(Self.sCookie, forHTTPHeaderField: "S-COOKIE")
        }
        _ = method
        for (field, value) in headers where !field.isEmpty && !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = packet.body

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatterflyEncryptWallError.invalidResponse
        }
        AppLog.info(
            "Chatterfly EncryptWall response status=\(httpResponse.statusCode) requestBytes=\(packet.body.count) responseBytes=\(data.count)"
        )

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let decoded = try? ChatterflyEncryptWallPacket.decryptResponse(data, aesKey: packet.aesKey, aesIV: packet.aesIV) {
                return decoded
            }
            throw ChatterflyEncryptWallError.httpStatus(httpResponse.statusCode)
        }
        return try ChatterflyEncryptWallPacket.decryptResponse(data, aesKey: packet.aesKey, aesIV: packet.aesIV)
    }

    func fetchUserInfo(accessToken: String) async throws -> (userID: String, payload: [String: Any]) {
        let response = try await request(
            urlString: ChatterflyEncryptWallPacket.userInfoURL,
            method: "POST",
            body: nil,
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        let (userID, payload) = try Self.parseUserInfoResponse(response)
        return (userID, payload)
    }

    static func nativeSpeechHeaders(userID: String?) -> [String: String] {
        let effectiveUserID = ChatterflyNativeIdentityStore.currentUserID() ?? userID
        let qimei36 = deviceID
        return [
            "S-COOKIE": ChatterflySCookie.make(
                inputMethodVersion: inputMethodVersion,
                userID: effectiveUserID,
                qimei36: qimei36
            ),
            "S-COOKIE2": ChatterflySCookie.make2(
                inputMethodVersion: inputMethodVersion,
                userID: effectiveUserID,
                sgid: "",
                qimei36: qimei36
            )
        ]
    }

    static func nativeDeviceUUID() -> String? {
        nativeDeviceID
    }

    static func nativeASRDeviceID() -> String? {
        nativeQimei36 ?? nativeDeviceID
    }

    static func parseUserInfoResponse(_ response: Data) throws -> (userID: String, payload: [String: Any]) {
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let code = envelope["code"] as? NSNumber,
              code.intValue == 0,
              let payload = envelope["data"] as? [String: Any],
              let userID = payload["user_id"] as? String,
              !userID.isEmpty else {
            throw ChatterflyEncryptWallError.invalidResponse
        }
        return (userID, payload)
    }

    private static var sCookie: String {
        let userID = ChatterflyNativeIdentityStore.currentUserID()
            ?? ChatterflyAuthTokenStore.load()?.userID
        return ChatterflySCookie.make(
            inputMethodVersion: inputMethodVersion,
            userID: userID,
            qimei36: deviceID
        )
    }

    private static var deviceID: String {
        if let q36 = nativeQimei36, !q36.isEmpty {
            AppLog.info("Chatterfly EncryptWall using native Qimei36 for S-COOKIE qi length=\(q36.count)")
            return q36
        }
        if let nativeID = nativeDeviceID, !nativeID.isEmpty {
            AppLog.info("Chatterfly EncryptWall using native UUID fallback for S-COOKIE qi length=\(nativeID.count)")
            return nativeID
        }

        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: deviceIDKey), !saved.isEmpty {
            return saved
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }

    private static var nativeQimei36: String? {
        let inputMethodRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chatterfly/InputMethod", isDirectory: true)
        let basePreferences = inputMethodRoot
            .appendingPathComponent("ChatterflyPY/UserPreferences.plist")
        let userPreferencesRoot = inputMethodRoot
            .appendingPathComponent("ChatterflyPY.users", isDirectory: true)

        var preferenceURLs = [basePreferences]
        if let userDirectories = try? FileManager.default.contentsOfDirectory(
            at: userPreferencesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            preferenceURLs += userDirectories.map { $0.appendingPathComponent("UserPreferences.plist") }
        }

        guard let uuid = nativeDeviceID else { return nil }
        let key = sha256(Data((uuid + qimeiCacheSalt).utf8))
        let iv = sha256(key).prefix(kCCBlockSizeAES128)

        for preferenceURL in preferenceURLs {
            guard let preferences = NSDictionary(contentsOf: preferenceURL) as? [String: Any],
                  let encoded = preferences[qimeiCacheKey] as? String,
                  encoded.hasPrefix(qimeiCachePrefix),
                  let encrypted = Data(base64Encoded: String(encoded.dropFirst(qimeiCachePrefix.count))),
                  let decrypted = try? ChatterflyCrypto.aes(
                      encrypted,
                      key: key,
                      iv: Data(iv),
                      operation: CCOperation(kCCDecrypt)
                  ),
                  let q36 = String(data: decrypted, encoding: .utf8),
                  !q36.isEmpty else {
                continue
            }
            return q36
        }
        return nil
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    private static var nativeDeviceID: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chatterfly/InputMethod/ChatterflyPY/.uuid.dat")
        guard let data = try? Data(contentsOf: path),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              let uuid = dictionary["uuid"] as? String else {
            return nil
        }
        return uuid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
