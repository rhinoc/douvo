import CryptoKit
import Foundation

struct DoubaoAndroidPersonalLexiconSyncResult: Sendable, Equatable {
    let wordCount: Int
    let uploaded: Bool
}

enum DoubaoAndroidPersonalLexicon {
    private static let cacheDeviceIDKey = "androidASR.personalLexicon.deviceID"
    private static let cacheWordDigestsKey = "androidASR.personalLexicon.wordDigests"

    static func words(from rawValue: String) -> [String] {
        let separators = CharacterSet.newlines.union(
            CharacterSet(charactersIn: ",，、;；")
        )
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { word in
                let key = word.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    static func digest(word: String) -> String {
        SHA256.hash(data: Data(word.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func missingWords(
        words: [String],
        deviceID: String,
        defaults: UserDefaults = .standard
    ) -> [String] {
        guard defaults.string(forKey: cacheDeviceIDKey) == deviceID else {
            return words
        }
        let cachedDigests = Set(
            defaults.stringArray(forKey: cacheWordDigestsKey) ?? []
        )
        return words.filter { !cachedDigests.contains(digest(word: $0)) }
    }

    static func markUploaded(
        words: [String],
        deviceID: String,
        defaults: UserDefaults = .standard
    ) {
        let existingDigests: Set<String>
        if defaults.string(forKey: cacheDeviceIDKey) == deviceID {
            existingDigests = Set(
                defaults.stringArray(forKey: cacheWordDigestsKey) ?? []
            )
        } else {
            existingDigests = []
        }
        let uploadedDigests = words.map(digest(word:))
        defaults.set(deviceID, forKey: cacheDeviceIDKey)
        defaults.set(
            Array(existingDigests.union(uploadedDigests)).sorted(),
            forKey: cacheWordDigestsKey
        )
    }

    static func clearCache(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: cacheDeviceIDKey)
        defaults.removeObject(forKey: cacheWordDigestsKey)
    }
}

actor DoubaoAndroidPersonalLexiconSynchronizer {
    static let shared = DoubaoAndroidPersonalLexiconSynchronizer()

    func sync(
        vocabulary: String,
        credentials: DoubaoAndroidCredentials
    ) async throws -> DoubaoAndroidPersonalLexiconSyncResult {
        let words = DoubaoAndroidPersonalLexicon.words(from: vocabulary)
        guard !words.isEmpty else {
            return DoubaoAndroidPersonalLexiconSyncResult(wordCount: 0, uploaded: false)
        }
        let wordsToUpload = DoubaoAndroidPersonalLexicon.missingWords(
            words: words,
            deviceID: credentials.deviceId
        )
        if wordsToUpload.isEmpty {
            return DoubaoAndroidPersonalLexiconSyncResult(
                wordCount: words.count,
                uploaded: false
            )
        }

        let client = DoubaoAndroidPersonalLexiconClient(credentials: credentials)
        try await client.report(words: wordsToUpload)
        DoubaoAndroidPersonalLexicon.markUploaded(
            words: wordsToUpload,
            deviceID: credentials.deviceId
        )
        return DoubaoAndroidPersonalLexiconSyncResult(
            wordCount: words.count,
            uploaded: true
        )
    }
}

actor DoubaoAndroidPersonalLexiconClient {
    private typealias Identity = DoubaoAndroidClientIdentity

    static let appID = Int(Identity.aid)!
    static let package = Identity.package
    static let contextVersionName = Identity.versionName
    static let contextVersionCode = Identity.versionCode
    static let samiAppKey = "SYlxZr6LnvBaIVmF"
    static let contextResourceID = "asr.user.context"
    static let userAgent = Identity.userAgent

    private let credentials: DoubaoAndroidCredentials
    private let urlSession: URLSession
    private let getConfigURL: URL
    private let userWordsURL: URL
    private let wave: DoubaoAndroidWaveClient
    private var samiToken = ""

    init(
        credentials: DoubaoAndroidCredentials,
        urlSession: URLSession = .shared,
        getConfigURL: URL = URL(string: "https://ime.oceancloudapi.com/api/v1/user/get_config")!,
        handshakeURL: URL = URL(string: "https://keyhub.zijieapi.com/handshake")!,
        userWordsURL: URL = URL(string: "https://speech.bytedance.com/api/v3/context/ime/user_words")!
    ) {
        self.credentials = credentials
        self.urlSession = urlSession
        self.getConfigURL = getConfigURL
        self.userWordsURL = userWordsURL
        wave = DoubaoAndroidWaveClient(
            deviceID: credentials.deviceId,
            appID: Self.appID,
            userAgent: Self.userAgent,
            urlSession: urlSession,
            handshakeURL: handshakeURL
        )
    }

    func report(words: [String]) async throws {
        guard !words.isEmpty else { return }
        let token = try await ensureSamiToken()
        let payload: [String: Any] = [
            "user": [
                "uid": "0",
                "did": credentials.deviceId,
                "app_name": Self.package,
                "app_version": Self.contextVersionName,
                "sdk_version": "",
                "platform": "android",
                "experience_improve": false
            ],
            "user_words": words.map { ["word": $0] }
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: payload)
        let sealed = try await wave.seal(plaintext)

        var request = URLRequest(url: userWordsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.contextVersionName, forHTTPHeaderField: "app_version")
        request.setValue(String(Self.appID), forHTTPHeaderField: "app_id")
        request.setValue("android", forHTTPHeaderField: "os_type")
        request.setValue(Self.contextResourceID, forHTTPHeaderField: "x-api-resource-id")
        request.setValue(Self.samiAppKey, forHTTPHeaderField: "x-api-app-key")
        request.setValue(token, forHTTPHeaderField: "x-api-token")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-api-request-id")
        for (name, value) in sealed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = sealed.body

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, operation: "Personal lexicon upload")
        let responsePayload: Data
        let responseEncrypted: Bool
        if let http = response as? HTTPURLResponse,
           let encodedNonce = http.value(forHTTPHeaderField: "x-tt-e-p"),
           let nonce = Data(base64Encoded: encodedNonce),
           !data.isEmpty {
            responsePayload = try await wave.open(data, nonce: nonce)
            responseEncrypted = true
        } else {
            responsePayload = data
            responseEncrypted = false
        }
        let responseKeys = try Self.validateServicePayload(responsePayload)
        AppLog.info(
            "Android personal lexicon upload accepted words=\(words.count) responseBytes=\(responsePayload.count) encryptedResponse=\(responseEncrypted) responseKeys=\(responseKeys.joined(separator: ","))"
        )
    }

    private func ensureSamiToken() async throws -> String {
        if !samiToken.isEmpty { return samiToken }
        let token = try await fetchSamiToken()
        samiToken = token
        return token
    }

    private func fetchSamiToken() async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "sami_app_key": Self.samiAppKey
        ])
        var components = URLComponents(
            url: getConfigURL,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "os", value: "android"),
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "_rticket", value: String(Self.currentTimeMillis())),
            URLQueryItem(name: "cdid", value: credentials.cdid),
            URLQueryItem(name: "channel", value: "official"),
            URLQueryItem(name: "aid", value: String(Self.appID)),
            URLQueryItem(name: "app_name", value: "oime"),
            URLQueryItem(name: "version_code", value: Self.contextVersionCode),
            URLQueryItem(name: "version_name", value: Self.contextVersionName)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.contextVersionName, forHTTPHeaderField: "app_version")
        request.setValue(String(Self.appID), forHTTPHeaderField: "app_id")
        request.setValue("Android", forHTTPHeaderField: "os_type")
        request.setValue(Self.md5Hex(body), forHTTPHeaderField: "x-ss-stub")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, operation: "Personal lexicon token request")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let token = payload["sami_token"] as? String,
              !token.isEmpty else {
            throw Self.error("Personal lexicon token response was incomplete")
        }
        return token
    }

    private static func validate(_ response: URLResponse, operation: String) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw error("\(operation) failed with HTTP \(status)", code: status)
        }
    }

    private static func validateServicePayload(_ data: Data) throws -> [String] {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let code = (json["code"] as? NSNumber)?.intValue
            ?? (json["status_code"] as? NSNumber)?.intValue
        if let code, code != 0 {
            throw error("Personal lexicon service rejected the upload", code: code)
        }
        return json.keys.sorted()
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func error(_ description: String, code: Int = 1) -> NSError {
        NSError(
            domain: "Douvo.AndroidPersonalLexicon",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
