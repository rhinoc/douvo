import Foundation

struct ASRDemoDiagnosticResult: Sendable {
    let provider: ASRProvider
    let openedProviders: [String]
    let finishedProviders: [String]
    let resultCharactersByProvider: [String: Int]
    let errorsByProvider: [String: String]
    let audioPath: String
    let durationMilliseconds: Int

    var isHealthy: Bool {
        let activeProviders = provider.activeProviderKeys
        return errorsByProvider.isEmpty
            && activeProviders.isSubset(of: Set(openedProviders))
            && activeProviders.isSubset(of: Set(finishedProviders))
            && activeProviders.allSatisfy { (resultCharactersByProvider[$0] ?? 0) > 0 }
    }

    var summary: String {
        let routeSummary = provider.activeProviderKeys.sorted().map { route in
            let chars = resultCharactersByProvider[route] ?? 0
            if let error = errorsByProvider[route] {
                return "\(route): failed (\(error))"
            }
            if finishedProviders.contains(route), chars > 0 {
                return "\(route): ok \(chars) chars"
            }
            if openedProviders.contains(route) {
                return "\(route): opened, no final result"
            }
            return "\(route): not opened"
        }.joined(separator: "; ")
        return "\(provider.rawValue) demo \(isHealthy ? "ok" : "failed") in \(durationMilliseconds)ms; \(routeSummary)"
    }
}

enum ASRDemoDiagnosticRunner {
    static func run(provider: ASRProvider) async throws -> ASRDemoDiagnosticResult {
        let audioURL = try DemoAudioStore.url()
        let packets = try DemoASRAudioPipeline.packets(from: audioURL, provider: provider)
        AppLog.info("ASR demo diagnostic audio prepared provider=\(provider.rawValue) path=\(audioURL.path) samples=\(packets.sampleCount) webPackets=\(packets.webPCM.count) androidPackets=\(packets.androidOpus.count)")

        var webParams: DoubaoASRParams?
        if provider.usesWebASR {
            guard let params = ASRParamsStore.load() else {
                throw NSError(domain: "Douvo.ASRDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web recognition parameters are missing"])
            }
            webParams = params
        }

        var androidCredentials: DoubaoAndroidCredentials?
        if provider.usesAndroidASR {
            androidCredentials = try await DoubaoAndroidCredentialStore.ensureCredentials()
        }

        let session = ASRDemoDiagnosticSession(provider: provider, audioURL: audioURL)
        return try await session.run(
            webParams: webParams,
            androidCredentials: androidCredentials,
            packets: packets
        )
    }
}

private final class ASRDemoDiagnosticSession: @unchecked Sendable {
    private let provider: ASRProvider
    private let audioURL: URL
    private let activeProviders: Set<String>
    private let lock = NSLock()
    private let startedAt = Date()
    private var webClient: DoubaoASRClient?
    private var androidClient: DoubaoAndroidASRClient?
    private var openedProviders = Set<String>()
    private var finishedProviders = Set<String>()
    private var latestTextByProvider: [String: String] = [:]
    private var errorsByProvider: [String: String] = [:]

    init(provider: ASRProvider, audioURL: URL) {
        self.provider = provider
        self.audioURL = audioURL
        activeProviders = provider.activeProviderKeys
    }

    func run(
        webParams: DoubaoASRParams?,
        androidCredentials: DoubaoAndroidCredentials?,
        packets: DemoASRAudioPackets
    ) async throws -> ASRDemoDiagnosticResult {
        configureClients()
        connect(webParams: webParams, androidCredentials: androidCredentials)
        defer {
            disconnect()
        }

        do {
            try await waitForOpen()
            try await sendPackets(packets)
            try await waitForFinish()

            let result = snapshot()
            writeDiagnostic(result)
            AppLog.info("ASR demo diagnostic finished \(result.summary)")
            return result
        } catch {
            let result = snapshot()
            writeDiagnostic(result)
            AppLog.error("ASR demo diagnostic failed \(result.summary) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func configureClients() {
        if provider.usesWebASR {
            let client = DoubaoASRClient()
            client.onOpen = { [weak self] in self?.markOpened("web") }
            client.onResult = { [weak self] result in self?.recordResult(result) }
            client.onFinish = { [weak self] in self?.markFinished("web") }
            client.onError = { [weak self] error in self?.markError(provider: "web", error: TranscriptionSessionError(error)) }
            client.onAuthError = { [weak self] in
                self?.markError(
                    provider: "web",
                    error: TranscriptionSessionError(domain: "Douvo.ASRAuth", code: 1, localizedDescription: "Web recognition authentication failed")
                )
            }
            webClient = client
        }

        if provider.usesAndroidASR {
            let client = DoubaoAndroidASRClient()
            client.onOpen = { [weak self] in self?.markOpened("android") }
            client.onResult = { [weak self] result in self?.recordResult(result) }
            client.onFinish = { [weak self] in self?.markFinished("android") }
            client.onError = { [weak self] error in self?.markError(provider: "android", error: TranscriptionSessionError(error)) }
            client.onAuthError = { [weak self] in
                self?.markError(
                    provider: "android",
                    error: TranscriptionSessionError(domain: "Douvo.ASRAuth", code: 1, localizedDescription: "Android recognition authentication failed")
                )
            }
            androidClient = client
        }
    }

    private func connect(webParams: DoubaoASRParams?, androidCredentials: DoubaoAndroidCredentials?) {
        if let webParams {
            webClient?.connect(params: webParams)
        }
        if let androidCredentials {
            androidClient?.connect(credentials: androidCredentials)
        }
    }

    private func waitForOpen() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if hasAnyOpenedProvider || activeProviders.allSatisfy({ errorsByProvider[$0] != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let opened = openedProvidersSnapshot
        guard !opened.isDisjoint(with: activeProviders) else {
            markUnopenedProvidersTimedOut()
            throw NSError(domain: "Douvo.ASRDemo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Demo recognition did not open any route"])
        }
    }

    private func sendPackets(_ packets: DemoASRAudioPackets) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            if openedProvidersSnapshot.contains("web"), let webClient {
                group.addTask {
                    for packet in packets.webPCM {
                        webClient.sendAudio(packet)
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    webClient.finishSending()
                }
            }

            if openedProvidersSnapshot.contains("android"), let androidClient {
                group.addTask {
                    for packet in packets.androidOpus {
                        androidClient.sendAudio(packet)
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    androidClient.finishSending()
                }
            }

            try await group.waitForAll()
        }
    }

    private func waitForFinish() async throws {
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            if openedProvidersSnapshot.allSatisfy({ finishedProvidersSnapshot.contains($0) || errorsByProviderSnapshot[$0] != nil }) {
                return
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        markUnfinishedProvidersTimedOut()
    }

    private func disconnect() {
        webClient?.disconnect()
        androidClient?.disconnect()
    }

    private var hasAnyOpenedProvider: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !openedProviders.isDisjoint(with: activeProviders)
    }

    private var openedProvidersSnapshot: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return openedProviders
    }

    private var finishedProvidersSnapshot: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return finishedProviders
    }

    private var errorsByProviderSnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return errorsByProvider
    }

    private func markOpened(_ provider: String) {
        lock.lock()
        openedProviders.insert(provider)
        lock.unlock()
        AppLog.info("ASR demo diagnostic opened provider=\(provider)")
    }

    private func markFinished(_ provider: String) {
        lock.lock()
        finishedProviders.insert(provider)
        lock.unlock()
        AppLog.info("ASR demo diagnostic finished provider=\(provider)")
    }

    private func recordResult(_ result: ASRRecognitionResult) {
        lock.lock()
        latestTextByProvider[result.provider] = result.text
        lock.unlock()
    }

    private func markError(provider: String, error: TranscriptionSessionError) {
        lock.lock()
        errorsByProvider[provider] = "\(error.domain)(\(error.code)): \(error.localizedDescription)"
        lock.unlock()
        AppLog.error("ASR demo diagnostic error provider=\(provider) error=\(error.localizedDescription)")
    }

    private func markUnopenedProvidersTimedOut() {
        lock.lock()
        for provider in activeProviders where !openedProviders.contains(provider) && errorsByProvider[provider] == nil {
            errorsByProvider[provider] = "open timeout"
        }
        lock.unlock()
    }

    private func markUnfinishedProvidersTimedOut() {
        lock.lock()
        for provider in openedProviders where !finishedProviders.contains(provider) && errorsByProvider[provider] == nil {
            errorsByProvider[provider] = "finish timeout"
        }
        lock.unlock()
    }

    private func snapshot() -> ASRDemoDiagnosticResult {
        lock.lock()
        let opened = openedProviders.sorted()
        let finished = finishedProviders.sorted()
        let resultCharacters = latestTextByProvider.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        let errors = errorsByProvider
        lock.unlock()

        return ASRDemoDiagnosticResult(
            provider: provider,
            openedProviders: opened,
            finishedProviders: finished,
            resultCharactersByProvider: resultCharacters,
            errorsByProvider: errors,
            audioPath: audioURL.path,
            durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private func writeDiagnostic(_ result: ASRDemoDiagnosticResult) {
        guard !result.isHealthy else { return }
        let payload: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "reason": "asr_demo_diagnostic",
            "selected_asr_provider": result.provider.rawValue,
            "opened_providers": result.openedProviders,
            "finished_providers": result.finishedProviders,
            "result_chars_by_provider": result.resultCharactersByProvider,
            "errors_by_provider": result.errorsByProvider,
            "audio_path": result.audioPath,
            "duration_ms": result.durationMilliseconds
        ]
        _ = ASRErrorDiagnosticStore.write(payload: payload, provider: result.provider.rawValue, reason: "demo_diagnostic")
    }
}

private enum DemoAudioStore {
    static func url() throws -> URL {
        if let url = Bundle.module.url(forResource: "ASRDemo", withExtension: "aiff") {
            return url
        }
        throw NSError(
            domain: "Douvo.ASRDemo",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Bundled demo audio is missing"]
        )
    }
}
