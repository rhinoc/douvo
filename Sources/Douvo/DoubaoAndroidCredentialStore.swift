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

enum DoubaoAndroidCredentialStore {
    private static let registerURL = URL(string: "https://log.snssdk.com/service/2/device_register/")!
    private static let settingsURL = URL(string: "https://is.snssdk.com/service/settings/v3/")!

    private static let aid = "401734"
    private static let appName = "oime"
    private static let versionCode = "100102018"
    private static let versionName = "1.1.2"
    private static let channel = "official"
    private static let package = "com.bytedance.android.doubaoime"
    private static let userAgent = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"

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
            AppLog.info("Android ASR credentials loaded deviceIdSet=\(!cached.deviceId.isEmpty)")
            return cached
        }

        AppLog.info("Android ASR credentials missing; registering device")
        var credentials = DoubaoAndroidCredentials.generated()
        try await registerDevice(&credentials)
        try await fetchASRToken(&credentials)
        try save(credentials)
        AppLog.info("Android ASR credentials saved deviceIdSet=\(!credentials.deviceId.isEmpty)")
        return credentials
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
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
            "aid": Int(aid)!,
            "app_name": appName,
            "version_code": Int(versionCode)!,
            "version_name": versionName,
            "manifest_version_code": Int(versionCode)!,
            "update_version_code": Int(versionCode)!,
            "channel": channel,
            "package": package,
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(md5Hex(body), forHTTPHeaderField: "x-ss-stub")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
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
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "aid", value: aid),
            URLQueryItem(name: "app_name", value: appName),
            URLQueryItem(name: "version_code", value: versionCode),
            URLQueryItem(name: "version_name", value: versionName)
        ]

        if includeDeviceId {
            items.append(URLQueryItem(name: "device_id", value: credentials.deviceId))
        } else {
            items.append(contentsOf: [
                URLQueryItem(name: "manifest_version_code", value: versionCode),
                URLQueryItem(name: "update_version_code", value: versionCode),
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
