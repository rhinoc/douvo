import Foundation

struct BageshuoHotWord: Equatable, Sendable {
    let id: String?
    let word: String
}

enum BageshuoHotWordsError: Error, LocalizedError, Equatable, Sendable {
    case authenticationRequired
    case httpStatus(Int)
    case invalidResponse
    case apiFailure(code: Int?, message: String)
    case pageLimitExceeded

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Bage Shuo login is required"
        case .httpStatus(let status):
            return "Bage Shuo hot words request failed (HTTP \(status))"
        case .invalidResponse:
            return "Bage Shuo hot words response is invalid"
        case .apiFailure(_, let message):
            return message
        case .pageLimitExceeded:
            return "Bage Shuo hot words list is too large"
        }
    }
}

struct BageshuoVocabularySyncResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case synced
        case failed
    }

    let status: Status
    let wordCount: Int
    let pushedWordCount: Int
    let errorDescription: String?
}

actor BageshuoHotWordsClient {
    static let endpoint = URL(string: "https://dict-typeless.youdao.com/api/v1/hot-words")!
    static let pageSize = 100
    private static let maxPageCount = 201

    private let urlSession: URLSession
    private let endpoint: URL
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        urlSession: URLSession = .shared,
        endpoint: URL = BageshuoHotWordsClient.endpoint,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.urlSession = urlSession
        self.endpoint = endpoint
        self.nowMilliseconds = nowMilliseconds
    }

    func fetchAll(params: BageshuoASRParams) async throws -> [BageshuoHotWord] {
        guard params.hasRequiredAuthCookies else {
            throw BageshuoHotWordsError.authenticationRequired
        }

        var words: [BageshuoHotWord] = []
        for page in 0..<Self.maxPageCount {
            let pageWords = try await fetchPage(
                params: params,
                page: page,
                limit: Self.pageSize
            )
            words.append(contentsOf: pageWords)
            if pageWords.count < Self.pageSize {
                return Self.deduplicated(words)
            }
        }
        throw BageshuoHotWordsError.pageLimitExceeded
    }

    func create(word: String, params: BageshuoASRParams) async throws {
        guard params.hasRequiredAuthCookies else {
            throw BageshuoHotWordsError.authenticationRequired
        }
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWord.isEmpty else { return }
        let request = try Self.makeMutationRequest(
            endpoint: endpoint,
            params: params,
            method: "POST",
            body: ["word": normalizedWord],
            nowMilliseconds: nowMilliseconds()
        )
        try await sendMutation(request)
    }

    private func fetchPage(
        params: BageshuoASRParams,
        page: Int,
        limit: Int
    ) async throws -> [BageshuoHotWord] {
        let request = Self.makeListRequest(
            endpoint: endpoint,
            params: params,
            page: page,
            limit: limit,
            keyword: nil,
            nowMilliseconds: nowMilliseconds()
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BageshuoHotWordsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BageshuoHotWordsError.authenticationRequired
            }
            throw BageshuoHotWordsError.httpStatus(httpResponse.statusCode)
        }
        return try Self.parsePage(from: data)
    }

    static func makeListRequest(
        endpoint: URL = BageshuoHotWordsClient.endpoint,
        params: BageshuoASRParams,
        page: Int,
        limit: Int,
        keyword: String? = nil,
        nowMilliseconds: Int64
    ) -> URLRequest {
        let signingContext = BageshuoSigner.currentContext(deviceID: params.deviceID)
        let signedParameters = BageshuoSigner.signedParameters(
            context: signingContext,
            nowMilliseconds: nowMilliseconds
        )
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let keyword, !keyword.isEmpty {
            queryItems.append(URLQueryItem(name: "keyword", value: keyword))
        }
        queryItems.append(contentsOf: signedParameters.keys.sorted().compactMap { key in
            guard let value = signedParameters[key] else { return nil }
            return URLQueryItem(name: key, value: value)
        })
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(DoubaoClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        if let typelessUser = params.typelessUser, !typelessUser.isEmpty {
            request.setValue(typelessUser, forHTTPHeaderField: "X-Typeless-User")
        }
        return request
    }

    static func makeMutationRequest(
        endpoint: URL = BageshuoHotWordsClient.endpoint,
        params: BageshuoASRParams,
        method: String,
        body: [String: Any],
        nowMilliseconds: Int64
    ) throws -> URLRequest {
        let signingContext = BageshuoSigner.currentContext(deviceID: params.deviceID)
        let signedParameters = BageshuoSigner.signedParameters(
            context: signingContext,
            nowMilliseconds: nowMilliseconds
        )
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = signedParameters.keys.sorted().compactMap { key in
            guard let value = signedParameters[key] else { return nil }
            return URLQueryItem(name: key, value: value)
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DoubaoClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://dict.youdao.com", forHTTPHeaderField: "Origin")
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        if let typelessUser = params.typelessUser, !typelessUser.isEmpty {
            request.setValue(typelessUser, forHTTPHeaderField: "X-Typeless-User")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sendMutation(_ request: URLRequest) async throws {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BageshuoHotWordsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BageshuoHotWordsError.authenticationRequired
            }
            throw BageshuoHotWordsError.httpStatus(httpResponse.statusCode)
        }
        try Self.parseMutationResponse(from: data)
    }

    static func parsePage(from data: Data) throws -> [BageshuoHotWord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BageshuoHotWordsError.invalidResponse
        }

        if let code = integerValue(root["code"]), code != 0, code != 200 {
            throw BageshuoHotWordsError.apiFailure(
                code: code,
                message: stringValue(root["msg"]) ?? stringValue(root["message"]) ?? "Bage Shuo hot words request failed"
            )
        }

        guard let items = root["data"] as? [[String: Any]] else {
            throw BageshuoHotWordsError.invalidResponse
        }
        return try items.map { item in
            guard let word = stringValue(item["word"]), !word.isEmpty else {
                throw BageshuoHotWordsError.invalidResponse
            }
            return BageshuoHotWord(
                id: stringValue(item["hotWordId"]),
                word: word
            )
        }
    }

    static func parseMutationResponse(from data: Data) throws {
        guard !data.isEmpty else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BageshuoHotWordsError.invalidResponse
        }
        if let code = integerValue(root["code"]), code != 0, code != 200 {
            throw BageshuoHotWordsError.apiFailure(
                code: code,
                message: stringValue(root["msg"]) ?? stringValue(root["message"]) ?? "Bage Shuo hot words request failed"
            )
        }
    }

    private static func deduplicated(_ words: [BageshuoHotWord]) -> [BageshuoHotWord] {
        var seen = Set<String>()
        return words.filter { hotWord in
            let key = hotWord.word.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

enum BageshuoVocabularyStore {
    private static let wordsKey = "bageshuo.vocabulary.words"
    private static let lastSyncedAtKey = "bageshuo.vocabulary.lastSyncedAt"

    static var importedWords: [String] {
        UserDefaults.standard.stringArray(forKey: wordsKey) ?? []
    }

    static var importedWordCount: Int {
        importedWords.count
    }

    static var lastSyncedAt: Date? {
        UserDefaults.standard.object(forKey: lastSyncedAtKey) as? Date
    }

    static func replaceImportedWords(_ words: [String]) {
        let normalized = DoubaoAndroidPersonalLexicon.words(from: words.joined(separator: "\n"))
        UserDefaults.standard.set(normalized, forKey: wordsKey)
        UserDefaults.standard.set(Date(), forKey: lastSyncedAtKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: wordsKey)
        UserDefaults.standard.removeObject(forKey: lastSyncedAtKey)
    }

    static func mergedVocabulary(manualVocabulary: String) -> String {
        mergedVocabulary(manualVocabulary: manualVocabulary, importedWords: importedWords)
    }

    static func mergedVocabulary(
        manualVocabulary: String,
        importedWords: [String]
    ) -> String {
        let manualWords = DoubaoAndroidPersonalLexicon.words(from: manualVocabulary)
        let allWords = DoubaoAndroidPersonalLexicon.words(
            from: (manualWords + importedWords).joined(separator: "\n")
        )
        return allWords.joined(separator: "\n")
    }
}

actor BageshuoVocabularySynchronizer {
    static let shared = BageshuoVocabularySynchronizer()

    private let client: BageshuoHotWordsClient

    init(client: BageshuoHotWordsClient = BageshuoHotWordsClient()) {
        self.client = client
    }

    func synchronizeBidirectionally(
        params: BageshuoASRParams? = nil
    ) async -> BageshuoVocabularySyncResult {
        let effectiveParams: BageshuoASRParams?
        if let params {
            effectiveParams = params
        } else {
            let storedParams = BageshuoASRParamsStore.load()
            if BageshuoASRParamsStore.credentialSource == .installedApp {
                effectiveParams = await BageshuoASRParamsStore.rehydrateInstalledApp()
                    ?? storedParams
            } else {
                effectiveParams = storedParams
            }
        }
        guard let effectiveParams else {
            return failedResult(BageshuoHotWordsError.authenticationRequired)
        }

        var pushedWordCount = 0
        do {
            let remoteWords = try await client.fetchAll(params: effectiveParams)
            let remoteKeys = Set(remoteWords.map { normalizedKey($0.word) })
            let localWords = DoubaoAndroidPersonalLexicon.words(from: LocalLLMSettingsStore.vocabulary)
            let wordsToPush = localWords.filter { !remoteKeys.contains(normalizedKey($0)) }

            for word in wordsToPush {
                try await client.create(word: word, params: effectiveParams)
                pushedWordCount += 1
            }

            let finalRemoteWords = pushedWordCount == 0
                ? remoteWords
                : try await client.fetchAll(params: effectiveParams)
            BageshuoVocabularyStore.replaceImportedWords(finalRemoteWords.map(\.word))
            AppLog.info("Bage Shuo vocabulary synchronized remoteCount=\(finalRemoteWords.count) pushedCount=\(pushedWordCount)")
            return BageshuoVocabularySyncResult(
                status: .synced,
                wordCount: finalRemoteWords.count,
                pushedWordCount: pushedWordCount,
                errorDescription: nil
            )
        } catch is CancellationError {
            return failedResult(BageshuoHotWordsError.invalidResponse, pushedWordCount: pushedWordCount)
        } catch {
            AppLog.info("Bage Shuo vocabulary synchronization failed")
            return failedResult(error, pushedWordCount: pushedWordCount)
        }
    }

    private func failedResult(
        _ error: Error,
        pushedWordCount: Int = 0
    ) -> BageshuoVocabularySyncResult {
        BageshuoVocabularySyncResult(
            status: .failed,
            wordCount: BageshuoVocabularyStore.importedWordCount,
            pushedWordCount: pushedWordCount,
            errorDescription: error.localizedDescription
        )
    }

    private func normalizedKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension LocalLLMSettingsStore {
    static var effectiveVocabulary: String {
        BageshuoVocabularyStore.mergedVocabulary(manualVocabulary: vocabulary)
    }
}
