import CryptoKit
import Foundation

struct DoubaoAndroidCredentials: Codable, Sendable {
    var deviceId: String
    var installId: String
    var cdid: String
    var openudid: String
    var clientudid: String
    var token: String

    var isComplete: Bool {
        !deviceId.isEmpty && !token.isEmpty
    }

    static func generated() -> DoubaoAndroidCredentials {
        DoubaoAndroidCredentials(
            deviceId: "",
            installId: "",
            cdid: UUID().uuidString,
            openudid: Data((0..<8).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined(),
            clientudid: UUID().uuidString,
            token: ""
        )
    }
}

enum DoubaoAndroidClientIdentity {
    static let webSocketURL = URL(string: "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws")!
    static let aid = "401734"
    static let appName = "oime"
    static let versionCode = "100316010"
    static let versionName = "1.3.16"
    static let channel = "official"
    static let package = "com.bytedance.android.doubaoime"
    static let userAgent = "com.bytedance.android.doubaoime/100316010 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"

    static func runtimeDiagnostics() -> String {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "bundleID=\(bundleID) version=\(version) build=\(build) bundlePath=\(bundle.bundleURL.path)"
    }

    static func credentialDiagnostics(_ credentials: DoubaoAndroidCredentials) -> String {
        [
            valueDiagnostics("deviceID", credentials.deviceId),
            valueDiagnostics("installID", credentials.installId),
            valueDiagnostics("cdid", credentials.cdid),
            valueDiagnostics("openudid", credentials.openudid),
            valueDiagnostics("clientudid", credentials.clientudid),
            valueDiagnostics("appKey", credentials.token)
        ].joined(separator: " ")
    }

    static func frontierQueryDiagnostics(credentials: DoubaoAndroidCredentials) -> String {
        let query = Dictionary(
            uniqueKeysWithValues: frontierQueryItems(credentials: credentials).map { ($0.name, $0.value ?? "") }
        )
        let requiredFields = ["uid", "aid", "app_name", "did", "iid", "install_id", "token"]
        let missingFields = requiredFields.filter { query[$0]?.isEmpty ?? true }
        return [
            "queryFields=\(query.keys.sorted().joined(separator: ","))",
            "missingRequired=\(missingFields.isEmpty ? "none" : missingFields.joined(separator: ","))",
            "uid=\(query["uid"] ?? "<missing>")",
            "aid=\(query["aid"] ?? "<missing>")",
            valueDiagnostics("did", credentials.deviceId),
            valueDiagnostics("iid", credentials.installId),
            "transportTokenFields=device_id,aid",
            "transportTokenLength=\((query["token"] ?? "").utf8.count)"
        ].joined(separator: " ")
    }

    static func valueDiagnostics(_ name: String, _ value: String) -> String {
        "\(name)Set=\(!value.isEmpty) \(name)Length=\(value.utf8.count)"
    }

    static func authenticationToken(deviceID: String) -> String {
        let object = ["device_id": deviceID, "aid": aid]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            preconditionFailure("Static Android authentication token fields must be JSON encodable")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func frontierQueryItems(credentials: DoubaoAndroidCredentials) -> [URLQueryItem] {
        [
            URLQueryItem(name: "uid", value: "0"),
            URLQueryItem(name: "aid", value: aid),
            URLQueryItem(name: "app_name", value: appName),
            URLQueryItem(name: "did", value: credentials.deviceId),
            URLQueryItem(name: "iid", value: credentials.installId),
            URLQueryItem(name: "install_id", value: credentials.installId),
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "os_version", value: "16"),
            URLQueryItem(name: "version_code", value: versionCode),
            URLQueryItem(name: "update_version_code", value: versionCode),
            URLQueryItem(name: "version_name", value: versionName),
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "device_type", value: "Pixel 7 Pro"),
            URLQueryItem(name: "device_brand", value: "google"),
            URLQueryItem(name: "ip", value: "0"),
            URLQueryItem(name: "user_agent", value: ""),
            URLQueryItem(name: "forwarded", value: ""),
            URLQueryItem(name: "target", value: ""),
            URLQueryItem(name: "mobile", value: ""),
            URLQueryItem(name: "token", value: authenticationToken(deviceID: credentials.deviceId))
        ]
    }
}

enum DoubaoAndroidCredentialStore {
    private typealias Identity = DoubaoAndroidClientIdentity

    private static let registerURL = URL(string: "https://log.snssdk.com/service/2/device_register/")!
    private static let settingsURL = URL(string: "https://is.snssdk.com/service/settings/v3/")!

    private static let urlSession = URLSession(configuration: makeURLSessionConfiguration())

    static func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return configuration
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("android_asr_credentials.json")
    }

    static func load() -> DoubaoAndroidCredentials? {
        guard let data = try? Data(contentsOf: fileURL),
              let credentials = try? JSONDecoder().decode(DoubaoAndroidCredentials.self, from: data),
              credentials.isComplete else {
            return nil
        }
        return credentials
    }

    static func ensureCredentials() async throws -> DoubaoAndroidCredentials {
        if let cached = load() {
            AppLog.info(
                "Android ASR credentials loaded \(Identity.credentialDiagnostics(cached))"
            )
            return cached
        }

        AppLog.info("Android ASR credentials missing; registering device")
        var credentials = DoubaoAndroidCredentials.generated()
        AppLog.info(
            "Android ASR registration identity \(Identity.credentialDiagnostics(credentials))"
        )
        try await registerDevice(&credentials)
        AppLog.info(
            "Android ASR device registration completed \(Identity.credentialDiagnostics(credentials))"
        )
        try await fetchASRToken(&credentials)
        AppLog.info(
            "Android ASR token fetch completed \(Identity.credentialDiagnostics(credentials))"
        )
        try save(credentials)
        AppLog.info(
            "Android ASR credentials saved \(Identity.credentialDiagnostics(credentials))"
        )
        return credentials
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        DoubaoAndroidPersonalLexicon.clearCache()
        AppLog.info("Android ASR credentials cleared path=\(fileURL.path)")
    }

    static func debugInfo() -> String {
        let credentials = load()
        return """
        Android Recognition Debug Info
        hasCredentials: \(credentials != nil)
        deviceIdSet: \(!(credentials?.deviceId ?? "").isEmpty)
        tokenSet: \(!(credentials?.token ?? "").isEmpty)
        credentialsPath: \(fileURL.path)
        """
    }

    private static func save(_ credentials: DoubaoAndroidCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func registerDevice(_ credentials: inout DoubaoAndroidCredentials) async throws {
        let now = currentTimeMillis()
        let header: [String: Any] = [
            "device_id": 0,
            "install_id": 0,
            "aid": Int(Identity.aid)!,
            "app_name": Identity.appName,
            "version_code": Int(Identity.versionCode)!,
            "version_name": Identity.versionName,
            "manifest_version_code": Int(Identity.versionCode)!,
            "update_version_code": Int(Identity.versionCode)!,
            "channel": Identity.channel,
            "package": Identity.package,
            "device_platform": "android",
            "os": "android",
            "os_api": "34",
            "os_version": "16",
            "device_type": "Pixel 7 Pro",
            "device_brand": "google",
            "device_model": "Pixel 7 Pro",
            "resolution": "1080*2400",
            "dpi": "420",
            "language": "zh",
            "timezone": 8,
            "access": "wifi",
            "rom": "UP1A.231005.007",
            "rom_version": "UP1A.231005.007",
            "openudid": credentials.openudid,
            "clientudid": credentials.clientudid,
            "cdid": credentials.cdid,
            "region": "CN",
            "tz_name": "Asia/Shanghai",
            "tz_offset": 28800,
            "sim_region": "cn",
            "carrier_region": "cn",
            "cpu_abi": "arm64-v8a",
            "build_serial": "unknown",
            "not_request_sender": 0,
            "sig_hash": "",
            "google_aid": "",
            "mc": "",
            "serial_number": ""
        ]
        let body: [String: Any] = [
            "magic_tag": "ss_app_log",
            "header": header,
            "_gen_time": now
        ]

        var request = URLRequest(url: url(registerURL, queryItems: commonQueryItems(credentials: credentials, includeDeviceId: false)))
        request.httpMethod = "POST"
        request.setValue(Identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, context: "Android recognition device registration")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = numericString(json["device_id"]),
              let installId = numericString(json["install_id"]),
              deviceId != "0" else {
            throw NSError(domain: "Douvo.AndroidASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Android recognition device registration returned invalid identifiers"])
        }

        credentials.deviceId = deviceId
        credentials.installId = installId
    }

    private static func fetchASRToken(_ credentials: inout DoubaoAndroidCredentials) async throws {
        let body = "body=null"
        var request = URLRequest(url: url(settingsURL, queryItems: commonQueryItems(credentials: credentials, includeDeviceId: true)))
        request.httpMethod = "POST"
        request.setValue(Identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(md5Hex(body), forHTTPHeaderField: "x-ss-stub")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, context: "Android recognition token request")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = json["data"] as? [String: Any],
              let settings = dataObject["settings"] as? [String: Any],
              let asrConfig = settings["asr_config"] as? [String: Any],
              let token = asrConfig["app_key"] as? String,
              !token.isEmpty else {
            throw NSError(domain: "Douvo.AndroidASR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Android recognition token response missing app key"])
        }
        credentials.token = token
    }

    private static func commonQueryItems(credentials: DoubaoAndroidCredentials, includeDeviceId: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "os", value: "android"),
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "_rticket", value: String(currentTimeMillis())),
            URLQueryItem(name: "cdid", value: credentials.cdid),
            URLQueryItem(name: "channel", value: Identity.channel),
            URLQueryItem(name: "aid", value: Identity.aid),
            URLQueryItem(name: "app_name", value: Identity.appName),
            URLQueryItem(name: "version_code", value: Identity.versionCode),
            URLQueryItem(name: "version_name", value: Identity.versionName)
        ]

        if includeDeviceId {
            items.append(URLQueryItem(name: "device_id", value: credentials.deviceId))
        } else {
            items.append(contentsOf: [
                URLQueryItem(name: "manifest_version_code", value: Identity.versionCode),
                URLQueryItem(name: "update_version_code", value: Identity.versionCode),
                URLQueryItem(name: "resolution", value: "1080*2400"),
                URLQueryItem(name: "dpi", value: "420"),
                URLQueryItem(name: "device_type", value: "Pixel 7 Pro"),
                URLQueryItem(name: "device_brand", value: "google"),
                URLQueryItem(name: "language", value: "zh"),
                URLQueryItem(name: "os_api", value: "34"),
                URLQueryItem(name: "os_version", value: "16"),
                URLQueryItem(name: "ac", value: "wifi")
            ])
        }
        return items
    }

    private static func url(_ base: URL, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return components.url!
    }

    private static func validateHTTPResponse(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Douvo.AndroidASR", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "\(context) failed with HTTP \(statusCode)"])
        }
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func numericString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02X", $0) }.joined()
    }
}
