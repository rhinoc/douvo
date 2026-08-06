import Foundation

struct DoubaoASRParams: Codable {
    let cookies: [String: String]
    let cookieExpiresAt: [String: Date]
    let deviceId: String
    let webId: String

    var hasRequiredAuthCookies: Bool {
        hasRequiredAuthCookies(at: Date())
    }

    func hasRequiredAuthCookies(at date: Date) -> Bool {
        Self.authCookieNames.contains { name in
            guard let value = cookies[name] else { return false }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let expiresAt = cookieExpiresAt[name] else { return true }
            return expiresAt > date
        }
    }

    var cookieNamesForLog: String {
        cookies.keys.sorted().joined(separator: ",")
    }

    var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    static let authCookieNames: Set<String> = [
        "sessionid",
        "sessionid_ss",
        "sid_tt",
        "session_tlb_tag"
    ]

    init(httpCookies: [HTTPCookie], deviceId: String, webId: String) {
        var values: [String: String] = [:]
        var expirationDates: [String: Date] = [:]
        for cookie in httpCookies {
            values[cookie.name] = cookie.value
            if let expiresDate = cookie.expiresDate {
                expirationDates[cookie.name] = expiresDate
            } else {
                expirationDates.removeValue(forKey: cookie.name)
            }
        }
        self.cookies = values
        self.cookieExpiresAt = expirationDates
        self.deviceId = deviceId
        self.webId = webId
    }

    private enum CodingKeys: String, CodingKey {
        case cookies
        case cookieExpiresAt
        case deviceId
        case webId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cookies = try container.decode([String: String].self, forKey: .cookies)
        // Older files only stored cookie values. Missing expiry metadata means
        // the server must still be allowed to make the final auth decision.
        cookieExpiresAt = try container.decodeIfPresent([String: Date].self, forKey: .cookieExpiresAt) ?? [:]
        deviceId = try container.decode(String.self, forKey: .deviceId)
        webId = try container.decode(String.self, forKey: .webId)
    }
}

enum ASRParamsStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("asr_params.json")
    }

    static func load() -> DoubaoASRParams? {
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLog.info("ASR params load miss path=\(fileURL.path)")
            return nil
        }
        let params = try? JSONDecoder().decode(DoubaoASRParams.self, from: data)
        AppLog.info("ASR params load result=\(params != nil) hasAuthCookies=\(params?.hasRequiredAuthCookies ?? false) path=\(fileURL.path)")
        if let params, !params.hasRequiredAuthCookies {
            AppLog.error("ASR params invalid: missing auth cookies cookieNames=\(params.cookieNamesForLog)")
            clear()
            return nil
        }
        return params
    }

    static func save(_ params: DoubaoASRParams) {
        guard let data = try? JSONEncoder().encode(params) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        AppLog.info("ASR params saved path=\(fileURL.path) cookieCount=\(params.cookies.count) hasAuthCookies=\(params.hasRequiredAuthCookies) cookieNames=\(params.cookieNamesForLog)")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.info("ASR params cleared path=\(fileURL.path)")
    }

    static func loginDebugInfo() -> String? {
        guard let params = load() else { return nil }
        return """
        Douvo Login Debug Info
        hasRequiredAuthCookies: \(params.hasRequiredAuthCookies)
        cookieCount: \(params.cookies.count)
        cookieNames: \(params.cookieNamesForLog)
        deviceIdSet: \(!params.deviceId.isEmpty)
        webIdSet: \(!params.webId.isEmpty)
        paramsPath: \(fileURL.path)
        logPath: \(AppLog.fileURL.path)
        """
    }
}
