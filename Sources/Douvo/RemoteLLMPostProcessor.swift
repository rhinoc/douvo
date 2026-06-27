import Foundation
import Security

enum CorrectionBackend: String, CaseIterable, Identifiable, Sendable {
    case local
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            "Local"
        case .remote:
            "Remote"
        }
    }
}

enum RemoteLLMProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case ark
    case deepseek
    case siliconflow
    case openai
    case mimo
    case cometapi
    case openrouterFree
    case alibabaCoding
    case codingPlanX
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ark:
            "Ark"
        case .deepseek:
            "DeepSeek"
        case .openai:
            "OpenAI"
        case .siliconflow:
            "SiliconFlow"
        case .mimo:
            "Mimo"
        case .cometapi:
            "CometAPI"
        case .openrouterFree:
            "OpenRouter Free"
        case .alibabaCoding:
            "Alibaba Coding"
        case .codingPlanX:
            "CodingPlanX"
        case .custom:
            "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ark:
            "https://ark.cn-beijing.volces.com/api/v3"
        case .deepseek:
            "https://api.deepseek.com/v1"
        case .openai:
            "https://api.openai.com/v1"
        case .siliconflow:
            "https://api.siliconflow.cn/v1"
        case .mimo:
            "https://api.xiaomimimo.com/v1"
        case .cometapi:
            "https://api.cometapi.com/v1"
        case .openrouterFree:
            "https://openrouter.ai/api/v1"
        case .alibabaCoding:
            "https://coding-intl.dashscope.aliyuncs.com/v1"
        case .codingPlanX:
            "https://api.codingplanx.ai/v1"
        case .custom:
            ""
        }
    }

    var defaultModel: String {
        switch self {
        case .ark:
            "deepseek-v3-2"
        case .deepseek:
            "deepseek-v4-flash"
        case .openai:
            "gpt-4o"
        case .siliconflow:
            "Qwen/Qwen2.5-7B-Instruct"
        case .mimo:
            "xiaomi/mimo-v2-flash"
        case .cometapi:
            "gpt-4o"
        case .openrouterFree:
            "qwen/qwen3-coder:free"
        case .alibabaCoding:
            "qwen3-coder-plus"
        case .codingPlanX:
            "gpt-5-mini"
        case .custom:
            ""
        }
    }
}

struct RemoteLLMConfiguration: Sendable {
    let provider: RemoteLLMProvider
    let baseURL: String
    let apiKey: String
    let model: String
    let timeoutSeconds: TimeInterval
    let temperature: Double
    let reasoningMode: LocalLLMReasoningMode

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RemoteLLMModelProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var provider: RemoteLLMProvider
    var displayName: String
    var baseURL: String
    var model: String

    var detailText: String {
        provider.displayName
    }

    var hasModelConfiguration: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func custom(provider: RemoteLLMProvider = .custom) -> RemoteLLMModelProfile {
        RemoteLLMModelProfile(
            id: "custom:\(UUID().uuidString)",
            provider: provider,
            displayName: provider == .custom ? "Custom Remote Model" : provider.displayName,
            baseURL: provider.defaultBaseURL,
            model: provider.defaultModel
        )
    }
}

enum CorrectionSettingsStore {
    private enum Key {
        static let backend = "correction.backend"
    }

    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var backend: CorrectionBackend {
        get {
            let envValue = ProcessInfo.processInfo.environment["DOUVO_CORRECTION_BACKEND"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let envValue, let backend = CorrectionBackend(rawValue: envValue) {
                return backend
            }
            let value = defaults.string(forKey: Key.backend)
            return CorrectionBackend(rawValue: value ?? "") ?? .local
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.backend)
        }
    }

    static var postProcessingEnabled: Bool {
        get { LocalLLMSettingsStore.postProcessingEnabled }
        set { LocalLLMSettingsStore.postProcessingEnabled = newValue }
    }

    static var canEnablePostProcessing: Bool {
        switch backend {
        case .local:
            LocalLLMSettingsStore.canEnablePostProcessing
        case .remote:
            RemoteLLMSettingsStore.selectedProfile?.hasModelConfiguration == true
        }
    }
}

enum RemoteLLMSettingsStore {
    private enum Key {
        static let profiles = "remoteLLM.profiles.v3"
        static let selectedProfileID = "remoteLLM.selectedProfileID.v3"
        static let timeoutSeconds = "remoteLLM.timeoutSeconds"
        static let temperature = "remoteLLM.temperature"
    }

    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var profiles: [RemoteLLMModelProfile] {
        get {
            guard let data = defaults.data(forKey: Key.profiles),
                  let profiles = try? JSONDecoder().decode([RemoteLLMModelProfile].self, from: data),
                  !profiles.isEmpty
            else {
                return []
            }
            return profiles
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.profiles)
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: Key.selectedProfileID)
                return
            }
            let selectedID = defaults.string(forKey: Key.selectedProfileID)
            if selectedID == nil || !newValue.contains(where: { $0.id == selectedID }) {
                defaults.set(newValue[0].id, forKey: Key.selectedProfileID)
            }
        }
    }

    static var selectedProfileID: String? {
        get {
            if let value = defaults.string(forKey: Key.selectedProfileID),
               profiles.contains(where: { $0.id == value }) {
                return value
            }
            return profiles.first?.id
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedProfileID)
            } else {
                defaults.removeObject(forKey: Key.selectedProfileID)
            }
        }
    }

    static var selectedProfile: RemoteLLMModelProfile? {
        get {
            guard let selectedProfileID else { return profiles.first }
            return profiles.first { $0.id == selectedProfileID } ?? profiles.first
        }
        set {
            guard let newValue else {
                selectedProfileID = nil
                return
            }
            upsertProfile(newValue)
            selectedProfileID = newValue.id
        }
    }

    static func upsertProfile(_ profile: RemoteLLMModelProfile) {
        var nextProfiles = profiles
        if let index = nextProfiles.firstIndex(where: { $0.id == profile.id }) {
            nextProfiles[index] = profile
        } else {
            nextProfiles.append(profile)
        }
        profiles = nextProfiles
    }

    static func removeProfile(_ profile: RemoteLLMModelProfile) {
        let remaining = profiles.filter { $0.id != profile.id }
        profiles = remaining
    }

    static var timeoutSeconds: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.timeoutSeconds)
            return value > 0 ? value : 30
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.timeoutSeconds)
        }
    }

    static var temperature: Double {
        get {
            if defaults.object(forKey: Key.temperature) == nil {
                return 0
            }
            return defaults.double(forKey: Key.temperature)
        }
        set {
            defaults.set(max(0, min(newValue, 2)), forKey: Key.temperature)
        }
    }

    static var currentConfiguration: RemoteLLMConfiguration {
        guard let profile = selectedProfile else {
            return RemoteLLMConfiguration(
                provider: .custom,
                baseURL: "",
                apiKey: "",
                model: "",
                timeoutSeconds: timeoutSeconds,
                temperature: temperature,
                reasoningMode: .disabled
            )
        }
        return RemoteLLMConfiguration(
            provider: profile.provider,
            baseURL: profile.baseURL,
            apiKey: RemoteLLMCredentialStore.shared.apiKey(profile: profile) ?? "",
            model: profile.model,
            timeoutSeconds: timeoutSeconds,
            temperature: temperature,
            reasoningMode: .disabled
        )
    }
}

final class RemoteLLMCredentialStore: @unchecked Sendable {
    static let shared = RemoteLLMCredentialStore()

    private let service = "top.douvo.remote-llm"
    private let lock = NSLock()

    func apiKey(profile: RemoteLLMModelProfile) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(profile: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        guard status == errSecSuccess,
              let data = output as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    func setAPIKey(_ value: String, profile: RemoteLLMModelProfile) throws {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecItemDelete(baseQuery(profile: profile) as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(profile: profile)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError.status(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainCredentialError.status(status)
        }
    }

    private func baseQuery(profile: RemoteLLMModelProfile) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key.\(profile.id).v1"
        ]
    }
}

enum KeychainCredentialError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            "Keychain error \(status)"
        }
    }
}

actor CorrectionPostProcessor {
    static let shared = CorrectionPostProcessor()

    func correctedTextWithTrace(
        for rawText: String,
        requiresEnabled: Bool,
        backend: CorrectionBackend? = nil,
        localModel: LocalLLMModel? = nil,
        promptConfiguration: LocalLLMPromptConfiguration? = nil,
        generationProfile: LocalLLMGenerationProfile? = nil
    ) async throws -> LocalLLMPostprocessResult {
        let selectedBackend = backend ?? CorrectionSettingsStore.backend
        switch selectedBackend {
        case .local:
            return try await LocalLLMPostProcessor.shared.correctedTextWithTrace(
                for: rawText,
                model: localModel ?? LocalLLMPostProcessor.configuredModel,
                requiresEnabled: requiresEnabled,
                promptConfiguration: promptConfiguration,
                generationProfile: generationProfile
            )
        case .remote:
            return try await RemoteLLMPostProcessor.shared.correctedTextWithTrace(
                for: rawText,
                requiresEnabled: requiresEnabled,
                configuration: RemoteLLMSettingsStore.currentConfiguration,
                promptConfiguration: promptConfiguration,
                generationProfile: generationProfile
            )
        }
    }
}

actor RemoteLLMPostProcessor {
    static let shared = RemoteLLMPostProcessor()

    private static let bodyPreviewLimit = 240

    func validate(configuration: RemoteLLMConfiguration) async throws -> String {
        guard configuration.isConfigured else {
            throw RemoteLLMError.invalidConfiguration("Base URL, Model, and API Key are required.")
        }

        return try await sendChatCompletion(
            instructions: "You validate a text correction model connection. Reply with only OK.",
            userPrompt: "OK",
            configuration: configuration,
            generationProfile: LocalLLMGenerationProfile(
                reasoningMode: configuration.reasoningMode,
                maxTokens: 8
            )
        )
    }

    func correctedTextWithTrace(
        for rawText: String,
        requiresEnabled: Bool,
        configuration: RemoteLLMConfiguration,
        promptConfiguration: LocalLLMPromptConfiguration? = nil,
        generationProfile: LocalLLMGenerationProfile? = nil,
        savePromptSnapshot: Bool = true
    ) async throws -> LocalLLMPostprocessResult {
        let totalStart = Self.now()
        let prepareStart = Self.now()
        var timings: [TraceTiming] = []
        var metadata: [String: String] = [:]
        var debugInfo = LocalLLMPostprocessDebugInfo(
            systemPrompt: nil,
            userPrompt: nil,
            rawResponse: nil,
            cleanedResponse: nil
        )

        let input = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptConfiguration = promptConfiguration ?? .current
        let generationProfile = generationProfile ?? .currentCorrection
        let settingsEnabled = LocalLLMPostProcessor.isCorrectionEnabled
        let shouldRun = !requiresEnabled || settingsEnabled
        let punctuationStyle = promptConfiguration.punctuationStyle

        metadata["backend"] = "remote"
        metadata["enabled"] = String(settingsEnabled)
        metadata["requires_enabled"] = String(requiresEnabled)
        metadata["input_chars"] = String(input.count)
        metadata["provider"] = configuration.provider.rawValue
        metadata["provider_display_name"] = configuration.provider.displayName
        metadata["model"] = configuration.model
        metadata["base_url_host"] = Self.hostDescription(configuration.baseURL)
        metadata["punctuation_style"] = punctuationStyle.rawValue
        metadata["remove_filler_words"] = String(promptConfiguration.removeFillerWords)
        metadata["soften_emotional_language"] = String(promptConfiguration.softenEmotionalLanguage)
        metadata["output_style"] = promptConfiguration.outputStyle.rawValue
        metadata["output_style_strength"] = promptConfiguration.outputStyleStrength.rawValue
        metadata["reasoning_mode"] = generationProfile.reasoningMode.rawValue
        metadata["model_enable_thinking"] = String(generationProfile.reasoningMode.modelEnableThinking)

        guard !input.isEmpty else {
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "empty_input"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            metadata["outcome"] = "skipped"
            metadata["reason"] = "empty_input"
            return LocalLLMPostprocessResult(text: rawText, timings: timings, metadata: metadata, debugInfo: debugInfo)
        }

        guard shouldRun else {
            let finalText = LocalLLMPostProcessor.fallbackCorrectionText(
                for: rawText,
                vocabulary: "",
                punctuationStyle: punctuationStyle
            )
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "disabled"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            metadata["outcome"] = "skipped"
            metadata["reason"] = "disabled"
            metadata["output_chars"] = String(finalText.count)
            return LocalLLMPostprocessResult(text: finalText, timings: timings, metadata: metadata, debugInfo: debugInfo)
        }

        guard configuration.isConfigured else {
            let finalText = LocalLLMPostProcessor.fallbackCorrectionText(
                for: rawText,
                vocabulary: promptConfiguration.vocabulary,
                punctuationStyle: punctuationStyle
            )
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "missing_credentials"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            metadata["outcome"] = "skipped"
            metadata["reason"] = "missing_credentials"
            metadata["output_chars"] = String(finalText.count)
            return LocalLLMPostprocessResult(text: finalText, timings: timings, metadata: metadata, debugInfo: debugInfo)
        }

        timings.append(TraceTiming(name: "correction.prepare", milliseconds: Self.milliseconds(since: prepareStart)))

        do {
            let promptStart = Self.now()
            let instructions = LocalLLMPostProcessor.correctionInstructions(
                for: input,
                configuration: promptConfiguration
            )
            let userPrompt = LocalLLMPostProcessor.correctionPrompt(
                for: input,
                configuration: promptConfiguration
            )
            debugInfo = LocalLLMPostprocessDebugInfo(
                systemPrompt: instructions,
                userPrompt: userPrompt,
                rawResponse: nil,
                cleanedResponse: nil
            )
            if savePromptSnapshot {
                await PromptSnapshotStore.shared.saveIfChanged(systemPrompt: instructions, userPrompt: userPrompt)
            }
            timings.append(TraceTiming(
                name: "correction.build_prompt",
                milliseconds: Self.milliseconds(since: promptStart),
                metadata: [
                    "instructions_chars": String(instructions.count),
                    "prompt_chars": String(userPrompt.count),
                    "vocabulary_chars": String(promptConfiguration.vocabulary.count),
                    "max_tokens": generationProfile.maxTokens.map(String.init) ?? "unlimited"
                ]
            ))

            AppLog.info("Remote LLM postprocess start provider=\(configuration.provider.rawValue) model=\(configuration.model) inputChars=\(input.count)")
            let generateStart = Self.now()
            let response = try await sendChatCompletion(
                instructions: instructions,
                userPrompt: userPrompt,
                configuration: configuration,
                generationProfile: generationProfile
            )
            debugInfo = LocalLLMPostprocessDebugInfo(
                systemPrompt: instructions,
                userPrompt: userPrompt,
                rawResponse: response,
                cleanedResponse: nil
            )
            timings.append(TraceTiming(
                name: "correction.generate",
                milliseconds: Self.milliseconds(since: generateStart),
                metadata: ["response_chars": String(response.count)]
            ))

            let cleanStart = Self.now()
            let cleaned = LocalLLMPostProcessor.cleanCorrectionResponse(response)
            debugInfo = LocalLLMPostprocessDebugInfo(
                systemPrompt: instructions,
                userPrompt: userPrompt,
                rawResponse: response,
                cleanedResponse: cleaned
            )
            guard LocalLLMPostProcessor.isUsableCorrection(cleaned, original: input) else {
                let finalText = LocalLLMPostProcessor.fallbackCorrectionText(
                    for: rawText,
                    vocabulary: promptConfiguration.vocabulary,
                    punctuationStyle: punctuationStyle
                )
                timings.append(TraceTiming(
                    name: "correction.clean_validate",
                    milliseconds: Self.milliseconds(since: cleanStart),
                    metadata: ["output_chars": String(cleaned.count), "accepted": "false"]
                ))
                timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
                metadata["outcome"] = "rejected"
                metadata["output_chars"] = String(finalText.count)
                AppLog.error("Remote LLM postprocess rejected outputChars=\(cleaned.count)")
                return LocalLLMPostprocessResult(text: finalText, timings: timings, metadata: metadata, debugInfo: debugInfo)
            }

            let vocabularyNormalized = LocalLLMPostProcessor.applyCorrectionVocabularyNormalizations(
                to: cleaned,
                vocabulary: promptConfiguration.vocabulary
            )
            let finalText = LocalLLMPostProcessor.applyCorrectionPunctuationStyle(
                to: vocabularyNormalized,
                style: punctuationStyle
            )
            timings.append(TraceTiming(
                name: "correction.clean_validate",
                milliseconds: Self.milliseconds(since: cleanStart),
                metadata: ["output_chars": String(finalText.count), "accepted": "true"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            metadata["outcome"] = finalText == input ? "unchanged" : "corrected"
            metadata["output_chars"] = String(finalText.count)
            AppLog.info("Remote LLM postprocess done outputChars=\(finalText.count)")
            return LocalLLMPostprocessResult(text: finalText, timings: timings, metadata: metadata, debugInfo: debugInfo)
        } catch {
            let finalText = LocalLLMPostProcessor.fallbackCorrectionText(
                for: rawText,
                vocabulary: promptConfiguration.vocabulary,
                punctuationStyle: punctuationStyle
            )
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            metadata["outcome"] = "failed"
            metadata["error"] = error.localizedDescription
            metadata["output_chars"] = String(finalText.count)
            metadata["deterministic_punctuation_applied"] = String(finalText != rawText)
            AppLog.error("Remote LLM postprocess failed; using deterministic fallback error=\(error.localizedDescription)")
            return LocalLLMPostprocessResult(text: finalText, timings: timings, metadata: metadata, debugInfo: debugInfo)
        }
    }

    private func sendChatCompletion(
        instructions: String,
        userPrompt: String,
        configuration: RemoteLLMConfiguration,
        generationProfile: LocalLLMGenerationProfile
    ) async throws -> String {
        let url = try Self.chatCompletionsURL(from: configuration.baseURL)
        let body = Self.chatBody(
            instructions: instructions,
            userPrompt: userPrompt,
            configuration: configuration,
            generationProfile: generationProfile
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse("missing HTTP response")
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteLLMError.httpStatus(
                httpResponse.statusCode,
                Self.preview(bodyText, limit: Self.bodyPreviewLimit)
            )
        }
        return try Self.extractAssistantContent(from: data)
    }

    private static func chatBody(
        instructions: String,
        userPrompt: String,
        configuration: RemoteLLMConfiguration,
        generationProfile: LocalLLMGenerationProfile
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "temperature": configuration.temperature,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userPrompt]
            ]
        ]
        if let maxTokens = generationProfile.maxTokens {
            body["max_tokens"] = maxTokens
        }
        applyThinkingControl(to: &body, configuration: configuration)
        return body
    }

    private static func applyThinkingControl(
        to body: inout [String: Any],
        configuration: RemoteLLMConfiguration
    ) {
        let enabled = configuration.reasoningMode.modelEnableThinking
        switch configuration.provider {
        case .openai:
            if let effort = openAIReasoningEffort(model: configuration.model, enabled: enabled) {
                body["reasoning_effort"] = effort
            }
        case .deepseek:
            body["thinking"] = ["type": enabled ? "enabled" : "disabled"]
        case .ark, .siliconflow, .mimo, .cometapi, .alibabaCoding, .codingPlanX, .custom:
            body["enable_thinking"] = enabled
        case .openrouterFree:
            body["reasoning"] = [
                "effort": enabled ? "medium" : "none",
                "exclude": true
            ]
        }
    }

    private static func openAIReasoningEffort(model: String, enabled: Bool) -> String? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "openai/", with: "")
            .lowercased()
        if normalized.hasPrefix("gpt-5-pro") {
            return "high"
        }
        if normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("gpt-5") {
            return enabled ? "medium" : "low"
        }
        return nil
    }

    private static func chatCompletionsURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if trimmed.hasSuffix("/chat/completions") {
            value = trimmed
        } else {
            value = "\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        }
        guard let url = URL(string: value) else {
            throw RemoteLLMError.invalidConfiguration("Invalid base URL")
        }
        return url
    }

    private static func extractAssistantContent(from data: Data) throws -> String {
        let value = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = value as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RemoteLLMError.invalidResponse("missing choices[0].message.content")
        }
        return content
    }

    private static func hostDescription(_ baseURL: String) -> String {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "unknown"
    }

    private static func preview(_ value: String, limit: Int) -> String {
        if value.count <= limit {
            return value
        }
        return String(value.prefix(limit))
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }
}

enum RemoteLLMError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            message
        case .invalidResponse(let message):
            "Invalid response: \(message)"
        case .httpStatus(let status, let body):
            "Provider returned HTTP \(status): \(body)"
        }
    }
}
