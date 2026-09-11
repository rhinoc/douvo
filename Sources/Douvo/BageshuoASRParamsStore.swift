import CryptoKit
import Foundation

struct BageshuoASRParams: Codable, Sendable {
    private static let authenticationCookieNames: Set<String> = [
        "DICT_UT",
        "DICT-PC",
        "cf7",
        "umurscookie"
    ]

    let cookies: [String: String]
    let cookieExpiresAt: [String: Date]
    let typelessUser: String?
    let deviceID: String?

    var hasRequiredAuthCookies: Bool {
        hasRequiredAuthCookies(at: Date())
    }

    func hasRequiredAuthCookies(at date: Date) -> Bool {
        guard let typelessUser,
              !typelessUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return cookies.contains { name, value in
            guard Self.authenticationCookieNames.contains(name) else {
                return false
            }
            guard !name.isEmpty, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard let expiresAt = cookieExpiresAt[name] else { return true }
            return expiresAt > date
        }
    }

    var cookieHeader: String {
        cookies.keys.sorted().compactMap { name in
            guard let value = cookies[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    var cookieNamesForLog: String {
        cookies.keys.sorted().joined(separator: ",")
    }

    init(httpCookies: [HTTPCookie], typelessUser: String? = nil, deviceID: String? = nil) {
        var values: [String: String] = [:]
        var expirationDates: [String: Date] = [:]
        for cookie in httpCookies {
            values[cookie.name] = cookie.value
            if let expiresDate = cookie.expiresDate {
                expirationDates[cookie.name] = expiresDate
            }
        }
        cookies = values
        cookieExpiresAt = expirationDates
        self.typelessUser = typelessUser ?? values["DICT_UT"]
        self.deviceID = deviceID
    }

    init(
        cookies: [String: String],
        cookieExpiresAt: [String: Date] = [:],
        typelessUser: String? = nil,
        deviceID: String? = nil
    ) {
        self.cookies = cookies
        self.cookieExpiresAt = cookieExpiresAt
        self.typelessUser = typelessUser ?? cookies["DICT_UT"]
        self.deviceID = deviceID
    }
}

enum BageshuoASRParamsSource: String {
    case installedApp = "installed-app"
    case douvoWebView = "douvo-webview"
}

enum BageshuoInstalledAppCredentialImporter {
    private struct StoreData: Decodable {
        let login: LoginState?
        let deviceId: String?
        let accountSessionToken: String?
    }

    private struct LoginState: Decodable {
        let loggedIn: Bool?
        let account: String?
        let userId: String?
        let pc: String?
        let pci: String?
        let tp: String?
    }

    private static let accountPollURL = URL(string: "https://dict.youdao.com/login/acc/poll")!
    private static let rehydrateTimeout: TimeInterval = 8

    static var binaryCookiesURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HTTPStorages", isDirectory: true)
            .appendingPathComponent("com.bageshuo.binarycookies")
    }

    static var storeURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bageshuo", isDirectory: true)
            .appendingPathComponent("bageshuo-store.json")
    }

    static func load() -> BageshuoASRParams? {
        guard let data = try? Data(contentsOf: storeURL) else {
            return nil
        }
        let cookieData = try? Data(contentsOf: binaryCookiesURL)
        return params(from: data, cookieData: cookieData)
    }

    static func rehydrate() async -> BageshuoASRParams? {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(StoreData.self, from: data),
              let login = store.login,
              login.loggedIn == true,
              let typelessUser = nonEmpty(login.userId) ?? nonEmpty(login.account),
              let accountSessionToken = nonEmpty(store.accountSessionToken),
              let deviceID = nonEmpty(store.deviceId),
              let body = sessionRehydrateForm(accountSessionToken: accountSessionToken) else {
            AppLog.info("Bage Shuo session-rehydrate skipped reason=missing-installed-session")
            return nil
        }

        var request = URLRequest(url: accountPollURL)
        request.httpMethod = "POST"
        request.timeoutInterval = rehydrateTimeout
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(typelessUser, forHTTPHeaderField: "X-Typeless-User")
        request.setValue(DoubaoClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookieData = try? Data(contentsOf: binaryCookiesURL),
           let installedParams = params(from: data, cookieData: cookieData) {
            request.setValue(installedParams.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = rehydrateTimeout
        configuration.timeoutIntervalForResource = rehydrateTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                AppLog.info("Bage Shuo session-rehydrate result=rejected httpStatus=\(statusCode)")
                return nil
            }
            guard sessionRehydrateLoginValue(from: responseData) == true else {
                AppLog.info("Bage Shuo session-rehydrate result=rejected login=false")
                return nil
            }

            let responseCookies = cookies(from: httpResponse, url: accountPollURL)
            let refreshedParams = BageshuoASRParams(
                httpCookies: responseCookies,
                typelessUser: typelessUser,
                deviceID: deviceID
            )
            guard refreshedParams.hasRequiredAuthCookies else {
                AppLog.info("Bage Shuo session-rehydrate result=rejected reason=response-cookies-incomplete")
                return nil
            }
            AppLog.info("Bage Shuo session-rehydrate result=complete cookieNames=\(refreshedParams.cookieNamesForLog)")
            return refreshedParams
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.info("Bage Shuo session-rehydrate result=failed")
            return nil
        }
    }

    static func sessionRehydrateForm(accountSessionToken: String) -> Data? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "cf", value: "7"),
            URLQueryItem(name: "DICT-PC", value: accountSessionToken),
            URLQueryItem(name: "um", value: "true"),
            URLQueryItem(name: "product", value: "DICT")
        ]
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    static func sessionRehydrateLoginValue(from data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let login = dictionary["login"] as? Bool {
            return login
        }
        if let payload = dictionary["data"] as? [String: Any],
           let login = payload["login"] as? Bool {
            return login
        }
        return nil
    }

    private static func cookies(from response: HTTPURLResponse, url: URL) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        for (headerName, headerValue) in response.allHeaderFields {
            guard String(describing: headerName).caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            let values: [String]
            if let value = headerValue as? String {
                values = [value]
            } else if let value = headerValue as? [String] {
                values = value
            } else if let value = headerValue as? [Any] {
                values = value.compactMap { $0 as? String }
            } else {
                values = []
            }
            for value in values {
                result.append(contentsOf: HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": value],
                    for: url
                ))
            }
        }
        return result
    }

    static func params(from data: Data, cookieData: Data? = nil) -> BageshuoASRParams? {
        guard let store = try? JSONDecoder().decode(StoreData.self, from: data),
              let login = store.login,
              login.loggedIn == true,
              let typelessUser = nonEmpty(login.userId) ?? nonEmpty(login.account) else {
            return nil
        }

        // The original client obtains its Cookie header from the account
        // WebView. The persisted login JSON only contains a reduced set of
        // account fields, so prefer the native HTTP cookie store when it is
        // available and use those fields only as a last-resort reconstruction.
        let deviceID = nonEmpty(store.deviceId)

        if let cookieData,
           let cookieRecords = BageshuoBinaryCookies.records(from: cookieData),
           !cookieRecords.isEmpty {
            var cookieValues: [String: String] = [:]
            var expirations: [String: Date] = [:]
            for record in cookieRecords {
                cookieValues[record.name] = record.value
                if let expiresAt = record.expiresAt {
                    expirations[record.name] = expiresAt
                } else {
                    expirations.removeValue(forKey: record.name)
                }
            }
            let params = BageshuoASRParams(
                cookies: cookieValues,
                cookieExpiresAt: expirations,
                typelessUser: typelessUser,
                deviceID: deviceID
            )
            if params.hasRequiredAuthCookies {
                return params
            }
        }

        guard let pc = nonEmpty(login.pc),
              let pci = nonEmpty(login.pci),
              let tp = nonEmpty(login.tp) else {
            return nil
        }

        // Legacy installed-client fields are not the names used by the
        // WebView Cookie header. Keep this reconstruction only for machines
        // where the native cookie file is not available.
        let params = BageshuoASRParams(cookies: [
            "DICT-PC": pci,
            "cf7": pc,
            "umurscookie": tp
        ], typelessUser: typelessUser, deviceID: deviceID)
        return params.hasRequiredAuthCookies ? params : nil
    }

    static func cookieRecords(from data: Data) -> [BageshuoCookieRecord]? {
        BageshuoBinaryCookies.records(from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

struct BageshuoCookieRecord: Equatable, Sendable {
    let domain: String
    let name: String
    let path: String
    let value: String
    let expiresAt: Date?
}

private enum BageshuoBinaryCookies {
    private static let magic = Data([0x63, 0x6f, 0x6f, 0x6b])
    private static let pageMagic = Data([0x00, 0x00, 0x01, 0x00])
    private static let cookieHeaderSize = 56

    static func records(from data: Data) -> [BageshuoCookieRecord]? {
        guard data.count >= 12, data.prefix(4) == magic,
              let pageCount = uint32BE(data, at: 4),
              pageCount > 0, pageCount <= 128 else {
            return nil
        }

        let pageCountInt = Int(pageCount)
        let pageSizesEnd = 8 + pageCountInt * 4
        guard pageSizesEnd <= data.count else { return nil }

        var pageSizes: [Int] = []
        for index in 0..<pageCountInt {
            guard let pageSize = uint32BE(data, at: 8 + index * 4),
                  pageSize > 0,
                  pageSize <= UInt32(data.count - pageSizesEnd) else {
                return nil
            }
            pageSizes.append(Int(pageSize))
        }

        var pageOffset = pageSizesEnd
        var parsedRecords: [BageshuoCookieRecord] = []
        for pageSize in pageSizes {
            guard pageOffset <= data.count - pageSize else { return nil }
            let page = data.subdata(in: pageOffset..<(pageOffset + pageSize))
            guard let pageRecords = records(in: page) else { return nil }
            parsedRecords.append(contentsOf: pageRecords)
            pageOffset += pageSize
        }
        return parsedRecords
    }

    private static func records(in page: Data) -> [BageshuoCookieRecord]? {
        guard page.count >= 8, page.prefix(4) == pageMagic,
              let cookieCount = uint32LE(page, at: 4),
              cookieCount <= 10_000 else {
            return nil
        }

        let count = Int(cookieCount)
        let offsetsEnd = 8 + count * 4
        guard offsetsEnd <= page.count else { return nil }

        var records: [BageshuoCookieRecord] = []
        for index in 0..<count {
            guard let offset = uint32LE(page, at: 8 + index * 4),
                  offset <= UInt32(page.count),
                  let record = record(in: page, at: Int(offset)) else {
                return nil
            }
            records.append(record)
        }
        return records
    }

    private static func record(in page: Data, at offset: Int) -> BageshuoCookieRecord? {
        guard offset <= page.count - cookieHeaderSize,
              let size = uint32LE(page, at: offset),
              size >= UInt32(cookieHeaderSize),
              size <= UInt32(page.count - offset) else {
            return nil
        }

        let recordEnd = offset + Int(size)
        guard let urlOffset = uint32LE(page, at: offset + 16),
              let nameOffset = uint32LE(page, at: offset + 20),
              let pathOffset = uint32LE(page, at: offset + 24),
              let valueOffset = uint32LE(page, at: offset + 28),
              let expires = doubleLE(page, at: offset + 40),
              let domain = string(in: page, offset: offset + Int(urlOffset), end: recordEnd),
              let name = string(in: page, offset: offset + Int(nameOffset), end: recordEnd),
              let path = string(in: page, offset: offset + Int(pathOffset), end: recordEnd),
              let value = string(in: page, offset: offset + Int(valueOffset), end: recordEnd) else {
            return nil
        }

        let expiresAt = expires > 0 ? Date(timeIntervalSinceReferenceDate: expires) : nil
        return BageshuoCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expiresAt: expiresAt
        )
    }

    private static func string(in data: Data, offset: Int, end: Int) -> String? {
        guard offset >= 0, offset < end, end <= data.count else { return nil }
        let bytes = data[offset..<end]
        guard let terminator = bytes.firstIndex(of: 0) else { return nil }
        return String(data: bytes[..<terminator], encoding: .utf8)
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    private static func doubleLE(_ data: Data, at offset: Int) -> Double? {
        guard let bits = uint64LE(data, at: offset) else { return nil }
        return Double(bitPattern: bits)
    }

    private static func uint64LE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        return data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }
}

enum BageshuoASRParamsStore {
    private static let installedAppImportCompleteKey = "bageshuoInstalledAppImportComplete"
    private static let installedAppImportedFingerprintKey = "bageshuoInstalledAppImportedFingerprint"
    private static let credentialSourceKey = "bageshuoCredentialSource"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Douvo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("bageshuo_asr_params.json")
    }

    static func load() -> BageshuoASRParams? {
        let storedParams = loadStoredParams()
        guard let installedParams = BageshuoInstalledAppCredentialImporter.load() else {
            if let storedParams { return storedParams }
            AppLog.info("Bage Shuo params load miss ownPath=\(fileURL.path) installedPath=\(BageshuoInstalledAppCredentialImporter.storeURL.path)")
            return nil
        }

        var credentialSource = UserDefaults.standard.string(forKey: credentialSourceKey)
            .flatMap(BageshuoASRParamsSource.init(rawValue:))
        let installedFingerprint = installedCredentialFingerprint(installedParams)

        // Migrate state written by the first cookie importer. If the saved
        // credentials equal the installed-app credentials, they came from that
        // importer; otherwise they were obtained through Douvo's login window.
        if credentialSource == nil, let storedParams {
            credentialSource = storedParams.cookies == installedParams.cookies
                && storedParams.typelessUser == installedParams.typelessUser
                ? .installedApp
                : .douvoWebView
            UserDefaults.standard.set(credentialSource?.rawValue, forKey: credentialSourceKey)
            if credentialSource == .installedApp {
                UserDefaults.standard.set(installedFingerprint, forKey: installedAppImportedFingerprintKey)
            }
        }

        if shouldImportInstalledParams(
            completedInitialImport: UserDefaults.standard.bool(forKey: installedAppImportCompleteKey),
            storedParams: storedParams,
            installedParams: installedParams,
            credentialSource: credentialSource,
            lastImportedFingerprint: UserDefaults.standard.string(forKey: installedAppImportedFingerprintKey),
            installedFingerprint: installedFingerprint
        ) {
            saveImported(installedParams, fingerprint: installedFingerprint)
            AppLog.info("Bage Shuo params imported from installed app cookieNames=\(installedParams.cookieNamesForLog)")
            return installedParams
        }

        if let storedParams {
            return storedParams
        }

        AppLog.info("Bage Shuo params load miss ownPath=\(fileURL.path) installedPath=\(BageshuoInstalledAppCredentialImporter.storeURL.path)")
        return nil
    }

    static func shouldImportInstalledParams(
        completedInitialImport: Bool,
        storedParams: BageshuoASRParams?,
        installedParams: BageshuoASRParams,
        credentialSource: BageshuoASRParamsSource? = nil,
        lastImportedFingerprint: String? = nil,
        installedFingerprint: String? = nil
    ) -> Bool {
        guard completedInitialImport else { return true }
        guard storedParams != nil else { return false }

        // Credentials captured through Douvo's official login window must not
        // be replaced by a later change in the installed app's cookie store.
        guard credentialSource != .douvoWebView else { return false }

        // A missing fingerprint is a legacy state. It is handled by the
        // migration in load(), which first identifies the source from the
        // currently stored credentials.
        guard let lastImportedFingerprint,
              let installedFingerprint else { return false }
        return lastImportedFingerprint != installedFingerprint
    }

    static func rehydrateInstalledApp() async -> BageshuoASRParams? {
        await BageshuoInstalledAppCredentialImporter.rehydrate()
    }

    static var credentialSource: BageshuoASRParamsSource? {
        UserDefaults.standard.string(forKey: credentialSourceKey)
            .flatMap(BageshuoASRParamsSource.init(rawValue:))
    }

    private static func loadStoredParams() -> BageshuoASRParams? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        guard let params = try? JSONDecoder().decode(BageshuoASRParams.self, from: data),
              params.hasRequiredAuthCookies else {
            AppLog.error("Bage Shuo params invalid; clearing stored params path=\(fileURL.path)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        AppLog.info("Bage Shuo params loaded cookieCount=\(params.cookies.count) cookieNames=\(params.cookieNamesForLog)")
        return params
    }

    static func save(_ params: BageshuoASRParams) {
        persist(params)
        UserDefaults.standard.set(BageshuoASRParamsSource.douvoWebView.rawValue, forKey: credentialSourceKey)
        UserDefaults.standard.set(true, forKey: installedAppImportCompleteKey)
        AppLog.info("Bage Shuo params saved cookieCount=\(params.cookies.count) cookieNames=\(params.cookieNamesForLog)")
    }

    private static func saveImported(_ params: BageshuoASRParams, fingerprint: String) {
        persist(params)
        UserDefaults.standard.set(BageshuoASRParamsSource.installedApp.rawValue, forKey: credentialSourceKey)
        UserDefaults.standard.set(fingerprint, forKey: installedAppImportedFingerprintKey)
        UserDefaults.standard.set(true, forKey: installedAppImportCompleteKey)
    }

    private static func persist(_ params: BageshuoASRParams) {
        guard let data = try? JSONEncoder().encode(params) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.set(true, forKey: installedAppImportCompleteKey)
        UserDefaults.standard.removeObject(forKey: credentialSourceKey)
        UserDefaults.standard.removeObject(forKey: installedAppImportedFingerprintKey)
        AppLog.info("Bage Shuo params cleared path=\(fileURL.path)")
    }

    private static func installedCredentialFingerprint(_ params: BageshuoASRParams) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(params) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func loginDebugInfo() -> String? {
        guard let params = load() else { return nil }
        return """
        Douvo Bage Shuo Login Debug Info
        hasRequiredAuthCookies: \(params.hasRequiredAuthCookies)
        cookieCount: \(params.cookies.count)
        cookieNames: \(params.cookieNamesForLog)
        paramsPath: \(fileURL.path)
        logPath: \(AppLog.fileURL.path)
        """
    }
}
