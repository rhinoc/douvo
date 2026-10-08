import Foundation

struct ChatterflyAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let userID: String?
    let expiresAt: Date?

    var isUsable: Bool {
        !accessToken.isEmpty && (expiresAt == nil || expiresAt! > Date())
    }

    func withUserID(_ userID: String) -> ChatterflyAuthToken {
        ChatterflyAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            userID: userID,
            expiresAt: expiresAt
        )
    }

    static func from(payload: [String: Any]) -> ChatterflyAuthToken? {
        let values = flattened(payload)
        guard let accessToken = stringValue(values["access_token"] ?? values["accessToken"]),
              !accessToken.isEmpty else {
            return nil
        }

        let expiresAt: Date?
        if let expiresIn = numberValue(values["expires_in"] ?? values["expiresIn"]) {
            expiresAt = Date().addingTimeInterval(expiresIn)
        } else {
            expiresAt = nil
        }

        return ChatterflyAuthToken(
            accessToken: accessToken,
            refreshToken: stringValue(values["refresh_token"] ?? values["refreshToken"]),
            tokenType: stringValue(values["token_type"] ?? values["tokenType"]),
            userID: stringValue(values["uid"] ?? values["user_id"] ?? values["userId"] ?? values["oneid"]),
            expiresAt: expiresAt
        )
    }

    var debugInfo: String {
        let expiry = expiresAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "Chatterfly: accessTokenSet=\(!accessToken.isEmpty) refreshTokenSet=\(refreshToken?.isEmpty == false) expiresAt=\(expiry)"
    }

    private static func flattened(_ payload: [String: Any]) -> [String: Any] {
        var values = payload
        for key in ["data", "result", "token"] {
            if let nested = payload[key] as? [String: Any] {
                values.merge(nested) { current, _ in current }
            }
        }
        return values
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func numberValue(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }
}

enum ChatterflyAuthTokenStore {
    private static let nativeIdentityDisabledKey = "chatterflyNativeIdentityDisabled"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chatterfly_auth.json")
    }

    static var accessToken: String? {
        if let token = load(), token.isUsable {
            return token.accessToken
        }
        guard !UserDefaults.standard.bool(forKey: nativeIdentityDisabledKey) else {
            return nil
        }
        return ChatterflyNativeIdentityStore.currentAccessToken()
    }

    static var hasUsableCredentials: Bool {
        accessToken?.isEmpty == false
    }

    static func load() -> ChatterflyAuthToken? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatterflyAuthToken.self, from: data)
    }

    static func save(_ token: ChatterflyAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        UserDefaults.standard.set(false, forKey: nativeIdentityDisabledKey)
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func clear() {
        UserDefaults.standard.set(true, forKey: nativeIdentityDisabledKey)
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func debugInfo() -> String {
        if let token = load(), token.isUsable {
            return token.debugInfo
        }
        if !UserDefaults.standard.bool(forKey: nativeIdentityDisabledKey),
           ChatterflyNativeIdentityStore.currentAccessToken() != nil {
            return "Chatterfly: using installed input method credentials"
        }
        return "Chatterfly: not logged in"
    }
}

enum ChatterflyAuthBridgeParser {
    static let bridgeNames = [
        "ime.common.goBack",
        "ime.common.encryptWallRequest",
        "ime.common.closeLoading",
        "ime.common.beaconReport",
        "ime.common.getImeHRV",
        "ime.common.getQ36",
        "ime.login.notifyClientLoginSuccess",
        "ime.login.notifyClientLoginFailed"
    ]

    static func dictionary(bodyData: Data?, bodyString: String?) -> [String: Any]? {
        if let bodyData, let object = try? JSONSerialization.jsonObject(with: bodyData),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        if let bodyString, let data = bodyString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        return nil
    }

    static func parameter(bodyData: Data?, bodyString: String?) -> [String: Any]? {
        guard let dictionary = dictionary(bodyData: bodyData, bodyString: bodyString) else {
            return nil
        }
        return object(from: dictionary["param"]) ?? dictionary
    }

    static func callback(bodyData: Data?, bodyString: String?) -> String? {
        dictionary(bodyData: bodyData, bodyString: bodyString)?["callback"] as? String
    }

    static func token(bodyData: Data?, bodyString: String?) -> ChatterflyAuthToken? {
        guard let parameter = parameter(bodyData: bodyData, bodyString: bodyString) else {
            return nil
        }
        return ChatterflyAuthToken.from(payload: parameter)
    }

    private static func object(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dictionary = object as? [String: Any] { return dictionary }
        if let nestedString = object as? String,
           let nestedData = nestedString.data(using: .utf8),
           let nestedObject = try? JSONSerialization.jsonObject(with: nestedData) {
            return nestedObject as? [String: Any]
        }
        return nil
    }
}
