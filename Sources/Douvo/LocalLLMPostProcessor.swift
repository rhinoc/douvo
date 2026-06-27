import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

struct LocalLLMModel: Hashable, Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        case huggingFace(repositoryID: String)
        case localDirectory(path: String)
    }

    let rawValue: String
    let displayName: String
    let detailText: String
    let downloadSizeText: String
    let source: Source

    var id: String { rawValue }

    var isHuggingFaceModel: Bool {
        if case .huggingFace = source { return true }
        return false
    }

    var isLocalDirectoryModel: Bool {
        if case .localDirectory = source { return true }
        return false
    }

    var repositoryID: String {
        switch source {
        case .huggingFace(let repositoryID):
            repositoryID
        case .localDirectory(let path):
            "local:\(path)"
        }
    }

    var configuration: ModelConfiguration {
        switch source {
        case .huggingFace(let repositoryID):
            ModelConfiguration(id: repositoryID)
        case .localDirectory(let path):
            ModelConfiguration(directory: URL(fileURLWithPath: path))
        }
    }

    var cacheURL: URL? {
        guard case .huggingFace(let repositoryID) = source else {
            return nil
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .appendingPathComponent("models--\(repositoryID.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    }

    var isDownloaded: Bool {
        switch source {
        case .huggingFace:
            return isHuggingFaceModelDownloaded
        case .localDirectory(let path):
            return Self.isValidLocalModelDirectory(URL(fileURLWithPath: path))
        }
    }

    init?(
        rawValue: String
    ) {
        guard let model = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = model
    }

    static let light = builtIn(
        rawValue: "light",
        displayName: "Qwen3.5 0.8B 4bit",
        detailText: "Fast correction",
        downloadSizeText: "622 MB",
        repositoryID: "mlx-community/Qwen3.5-0.8B-MLX-4bit"
    )
    static let qwen35EightBit08B = builtIn(
        rawValue: "qwen35EightBit08B",
        displayName: "Qwen3.5 0.8B 8bit",
        detailText: "Fast 8bit correction",
        downloadSizeText: "1.0 GB",
        repositoryID: "mlx-community/Qwen3.5-0.8B-8bit"
    )
    static let qwen35EightBit2B = builtIn(
        rawValue: "qwen35EightBit2B",
        displayName: "Qwen3.5 2B 8bit",
        detailText: "Balanced correction",
        downloadSizeText: "2.7 GB",
        repositoryID: "mlx-community/Qwen3.5-2B-8bit"
    )
    static let quality = builtIn(
        rawValue: "quality",
        displayName: "Qwen3.5 4B 4bit",
        detailText: "Quality correction",
        downloadSizeText: "3.1 GB",
        repositoryID: "mlx-community/Qwen3.5-4B-MLX-4bit"
    )
    static var allCases: [LocalLLMModel] {
        builtInCases + LocalLLMSettingsStore.customModels
    }

    static func localDirectory(
        id: String,
        displayName: String,
        path: String
    ) -> LocalLLMModel {
        LocalLLMModel(
            rawValue: id,
            displayName: displayName,
            detailText: "Local MLX model",
            downloadSizeText: "Local Folder",
            source: .localDirectory(path: path)
        )
    }

    static func isValidLocalModelDirectory(_ url: URL) -> Bool {
        hasModelFiles(in: url)
    }

    private init(
        rawValue: String,
        displayName: String,
        detailText: String,
        downloadSizeText: String,
        source: Source
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.detailText = detailText
        self.downloadSizeText = downloadSizeText
        self.source = source
    }

    private static func builtIn(
        rawValue: String,
        displayName: String,
        detailText: String,
        downloadSizeText: String,
        repositoryID: String
    ) -> LocalLLMModel {
        LocalLLMModel(
            rawValue: rawValue,
            displayName: displayName,
            detailText: detailText,
            downloadSizeText: downloadSizeText,
            source: .huggingFace(repositoryID: repositoryID)
        )
    }

    private static let builtInCases: [LocalLLMModel] = [
        .light,
        .qwen35EightBit08B,
        .qwen35EightBit2B,
        .quality
    ]

    private var isHuggingFaceModelDownloaded: Bool {
        guard let cacheURL else { return false }
        let snapshotsURL = cacheURL.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? FileManager.default.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        return snapshotURLs.contains { snapshotURL in
            Self.hasModelFiles(in: snapshotURL)
        }
    }

    private static func hasModelFiles(in url: URL) -> Bool {
        let hasConfig = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.json").path
        )
        let hasTokenizer = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("tokenizer.json").path
        ) || FileManager.default.fileExists(
            atPath: url.appendingPathComponent("tokenizer_config.json").path
        )

        guard hasConfig, hasTokenizer else {
            return false
        }

        let hasWeights = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).contains { url in
            return url.pathExtension == "safetensors"
        }) ?? false

        return hasWeights
    }
}

struct LocalLLMPromptConfiguration: Sendable {
    let systemPromptTemplate: String
    let userPromptTemplate: String
    let vocabulary: String
    let punctuationStyle: PunctuationStyle
    let removeFillerWords: Bool
    let softenEmotionalLanguage: Bool
    let outputStyle: LocalLLMOutputStyle
    let outputStyleStrength: LocalLLMOutputStyleStrength

    var outputStyleInstruction: String {
        outputStyle.instruction(strength: outputStyleStrength)
    }

    static var current: LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
            systemPromptTemplate: LocalLLMSettingsStore.systemPrompt,
            userPromptTemplate: LocalLLMSettingsStore.userPromptTemplate,
            vocabulary: LocalLLMSettingsStore.vocabulary,
            punctuationStyle: LocalLLMSettingsStore.punctuationStyle,
            removeFillerWords: LocalLLMSettingsStore.removeFillerWords,
            softenEmotionalLanguage: LocalLLMSettingsStore.softenEmotionalLanguage,
            outputStyle: LocalLLMSettingsStore.outputStyle,
            outputStyleStrength: LocalLLMSettingsStore.outputStyleStrength
        )
    }
}

enum LocalLLMReasoningMode: String, CaseIterable, Sendable {
    case disabled
    case enabled

    var modelEnableThinking: Bool {
        self == .enabled
    }
}

struct LocalLLMGenerationProfile: Sendable {
    let reasoningMode: LocalLLMReasoningMode
    let maxTokens: Int?

    static var currentCorrection: LocalLLMGenerationProfile {
        asrCorrection(reasoningMode: .disabled)
    }

    static func asrCorrection(reasoningMode: LocalLLMReasoningMode) -> LocalLLMGenerationProfile {
        LocalLLMGenerationProfile(
            reasoningMode: reasoningMode,
            maxTokens: reasoningMode == .enabled ? 1536 : 96
        )
    }

    static func promptLab(reasoningMode: LocalLLMReasoningMode) -> LocalLLMGenerationProfile {
        asrCorrection(reasoningMode: reasoningMode)
    }

    static func promptLab(
        reasoningMode: LocalLLMReasoningMode,
        maxTokens: Int?
    ) -> LocalLLMGenerationProfile {
        guard let maxTokens else {
            return promptLab(reasoningMode: reasoningMode)
        }
        return LocalLLMGenerationProfile(
            reasoningMode: reasoningMode,
            maxTokens: maxTokens > 0 ? maxTokens : nil
        )
    }

    var additionalContext: [String: any Sendable] {
        ["enable_thinking": reasoningMode.modelEnableThinking]
    }
}

actor LocalLLMPostProcessor {
    static let shared = LocalLLMPostProcessor()
    typealias ProgressHandler = @Sendable (Double) -> Void
    private enum State {
        case idle
        case loading(UUID, Task<ModelContainer, Error>)
        case loaded(ModelContainer)
    }

    private final class DeferredStateRelease: @unchecked Sendable {
        private var state: State?

        init(_ state: State?) {
            self.state = state
        }

        func release() {
            state = nil
        }
    }

    private var states: [LocalLLMModel: State] = [:]
    private var runtimeUnavailableReason: String?

    func correctedText(
        for rawText: String,
        model: LocalLLMModel,
        requiresEnabled: Bool,
        promptConfiguration: LocalLLMPromptConfiguration? = nil,
        generationProfile: LocalLLMGenerationProfile? = nil
    ) async throws -> String {
        try await correctedTextWithTrace(
            for: rawText,
            model: model,
            requiresEnabled: requiresEnabled,
            promptConfiguration: promptConfiguration,
            generationProfile: generationProfile
        ).text
    }

    func correctedTextWithTrace(
        for rawText: String,
        model: LocalLLMModel,
        requiresEnabled: Bool,
        promptConfiguration: LocalLLMPromptConfiguration? = nil,
        generationProfile: LocalLLMGenerationProfile? = nil,
        savePromptSnapshot: Bool = true
    ) async throws -> LocalLLMPostprocessResult {
        let totalStart = Self.now()
        let prepareStart = Self.now()
        var timings: [TraceTiming] = []
        var traceMetadata: [String: String] = [:]
        var debugInfo = LocalLLMPostprocessDebugInfo(
            systemPrompt: nil,
            userPrompt: nil,
            rawResponse: nil,
            cleanedResponse: nil
        )

        let input = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptConfiguration = promptConfiguration ?? .current
        let generationProfile = generationProfile ?? .currentCorrection
        let settingsEnabled = Self.isEnabled
        let shouldRun = !requiresEnabled || settingsEnabled
        let punctuationStyle = promptConfiguration.punctuationStyle
        traceMetadata["enabled"] = String(settingsEnabled)
        traceMetadata["requires_enabled"] = String(requiresEnabled)
        traceMetadata["input_chars"] = String(input.count)
        traceMetadata["model"] = model.repositoryID
        traceMetadata["model_display_name"] = model.displayName
        traceMetadata["model_state_before"] = modelStateDescription(for: model)
        traceMetadata["punctuation_style"] = punctuationStyle.rawValue
        traceMetadata["remove_filler_words"] = String(promptConfiguration.removeFillerWords)
        traceMetadata["soften_emotional_language"] = String(promptConfiguration.softenEmotionalLanguage)
        traceMetadata["output_style"] = promptConfiguration.outputStyle.rawValue
        traceMetadata["output_style_strength"] = promptConfiguration.outputStyleStrength.rawValue
        traceMetadata["reasoning_mode"] = generationProfile.reasoningMode.rawValue
        traceMetadata["model_enable_thinking"] = String(generationProfile.reasoningMode.modelEnableThinking)

        guard !input.isEmpty else {
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "empty_input"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = "skipped"
            traceMetadata["reason"] = "empty_input"
            return LocalLLMPostprocessResult(
                text: rawText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        }

        guard shouldRun else {
            let finalText = Self.applyPunctuationStyle(to: rawText, style: punctuationStyle)
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "disabled"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = "skipped"
            traceMetadata["reason"] = "disabled"
            traceMetadata["output_chars"] = String(finalText.count)
            traceMetadata["deterministic_punctuation_applied"] = String(finalText != rawText)
            return LocalLLMPostprocessResult(
                text: finalText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        }

        if let runtimeUnavailableReason {
            let finalText = Self.fallbackText(
                for: rawText,
                vocabulary: promptConfiguration.vocabulary,
                punctuationStyle: punctuationStyle
            )
            AppLog.error("Local LLM postprocess skipped; runtime unavailable reason=\(runtimeUnavailableReason)")
            timings.append(TraceTiming(
                name: "correction.prepare",
                milliseconds: Self.milliseconds(since: prepareStart),
                metadata: ["reason": "runtime_unavailable"]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = "skipped"
            traceMetadata["reason"] = "runtime_unavailable"
            traceMetadata["output_chars"] = String(finalText.count)
            traceMetadata["deterministic_punctuation_applied"] = String(finalText != rawText)
            return LocalLLMPostprocessResult(
                text: finalText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        }

        let isDownloaded = model.isDownloaded
        traceMetadata["model_downloaded"] = String(isDownloaded)
        timings.append(TraceTiming(name: "correction.prepare", milliseconds: Self.milliseconds(since: prepareStart)))

        guard isDownloaded else {
            let finalText = Self.fallbackText(
                for: rawText,
                vocabulary: promptConfiguration.vocabulary,
                punctuationStyle: punctuationStyle
            )
            AppLog.error("Local LLM postprocess skipped; model not downloaded model=\(model.repositoryID)")
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = "skipped"
            traceMetadata["reason"] = "model_not_downloaded"
            traceMetadata["output_chars"] = String(finalText.count)
            traceMetadata["deterministic_punctuation_applied"] = String(finalText != rawText)
            return LocalLLMPostprocessResult(
                text: finalText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        }

        do {
            let loadStart = Self.now()
            let container = try await modelContainer(for: model)
            timings.append(TraceTiming(
                name: "correction.load_model",
                milliseconds: Self.milliseconds(since: loadStart),
                metadata: ["model_state_before": traceMetadata["model_state_before"] ?? "unknown"]
            ))

            let promptStart = Self.now()
            let instructions = Self.instructions(for: input, configuration: promptConfiguration)
            let userPrompt = Self.prompt(for: input, configuration: promptConfiguration)
            debugInfo = LocalLLMPostprocessDebugInfo(
                systemPrompt: instructions,
                userPrompt: userPrompt,
                rawResponse: nil,
                cleanedResponse: nil
            )
            if savePromptSnapshot {
                await PromptSnapshotStore.shared.saveIfChanged(systemPrompt: instructions, userPrompt: userPrompt)
            }
            let session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: GenerateParameters(
                    maxTokens: generationProfile.maxTokens,
                    temperature: 0
                ),
                additionalContext: generationProfile.additionalContext
            )
            timings.append(TraceTiming(
                name: "correction.build_prompt",
                milliseconds: Self.milliseconds(since: promptStart),
                metadata: [
                    "instructions_chars": String(instructions.count),
                    "prompt_chars": String(userPrompt.count),
                    "vocabulary_chars": String(promptConfiguration.vocabulary.count),
                    "punctuation_style": punctuationStyle.rawValue,
                    "remove_filler_words": String(promptConfiguration.removeFillerWords),
                    "soften_emotional_language": String(promptConfiguration.softenEmotionalLanguage),
                    "output_style": promptConfiguration.outputStyle.rawValue,
                    "output_style_strength": promptConfiguration.outputStyleStrength.rawValue,
                    "reasoning_mode": generationProfile.reasoningMode.rawValue,
                    "model_enable_thinking": String(generationProfile.reasoningMode.modelEnableThinking),
                    "max_tokens": generationProfile.maxTokens.map(String.init) ?? "unlimited"
                ]
            ))

            AppLog.info("Local LLM postprocess start model=\(model.repositoryID) inputChars=\(input.count)")
            let generateStart = Self.now()
            let response = try await session.respond(to: userPrompt)
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
            let cleaned = Self.cleanResponse(response)
            debugInfo = LocalLLMPostprocessDebugInfo(
                systemPrompt: instructions,
                userPrompt: userPrompt,
                rawResponse: response,
                cleanedResponse: cleaned
            )
            guard Self.isUsableCorrection(cleaned, original: input) else {
                let finalText = Self.fallbackText(
                    for: rawText,
                    vocabulary: promptConfiguration.vocabulary,
                    punctuationStyle: punctuationStyle
                )
                timings.append(TraceTiming(
                    name: "correction.clean_validate",
                    milliseconds: Self.milliseconds(since: cleanStart),
                    metadata: [
                        "output_chars": String(cleaned.count),
                        "accepted": "false"
                    ]
                ))
                timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
                traceMetadata["outcome"] = "rejected"
                traceMetadata["output_chars"] = String(finalText.count)
                traceMetadata["punctuation_style"] = punctuationStyle.rawValue
                AppLog.error("Local LLM postprocess rejected outputChars=\(cleaned.count)")
                return LocalLLMPostprocessResult(
                    text: finalText,
                    timings: timings,
                    metadata: traceMetadata,
                    debugInfo: debugInfo
                )
            }

            let vocabularyNormalized = Self.applyVocabularyNormalizations(
                to: cleaned,
                vocabulary: promptConfiguration.vocabulary
            )
            let finalText = Self.applyPunctuationStyle(to: vocabularyNormalized, style: punctuationStyle)

            timings.append(TraceTiming(
                name: "correction.clean_validate",
                milliseconds: Self.milliseconds(since: cleanStart),
                metadata: [
                    "output_chars": String(finalText.count),
                    "accepted": "true",
                    "punctuation_style": punctuationStyle.rawValue
                ]
            ))
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = finalText == input ? "unchanged" : "corrected"
            traceMetadata["output_chars"] = String(finalText.count)
            traceMetadata["punctuation_style"] = punctuationStyle.rawValue
            AppLog.info("Local LLM postprocess done outputChars=\(finalText.count)")
            return LocalLLMPostprocessResult(
                text: finalText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        } catch {
            let finalText = Self.fallbackText(
                for: rawText,
                vocabulary: promptConfiguration.vocabulary,
                punctuationStyle: punctuationStyle
            )
            markRuntimeUnavailableIfNeeded(error)
            timings.append(TraceTiming(name: "correction.total", milliseconds: Self.milliseconds(since: totalStart)))
            traceMetadata["outcome"] = "failed"
            traceMetadata["error"] = error.localizedDescription
            traceMetadata["output_chars"] = String(finalText.count)
            traceMetadata["deterministic_punctuation_applied"] = String(finalText != rawText)
            AppLog.error("Local LLM postprocess failed; using deterministic fallback error=\(error.localizedDescription)")
            return LocalLLMPostprocessResult(
                text: finalText,
                timings: timings,
                metadata: traceMetadata,
                debugInfo: debugInfo
            )
        }
    }

    func preload(
        _ model: LocalLLMModel,
        onProgress: ProgressHandler? = nil
    ) async throws {
        _ = try await modelContainer(for: model, onProgress: onProgress)
    }

    func deleteDownloadedModel(_ model: LocalLLMModel) async throws {
        let scheduleStart = Self.now()
        guard let cacheURL = model.cacheURL else {
            AppLog.info("Local LLM delete skipped for local directory model=\(model.repositoryID)")
            let removedState = states.removeValue(forKey: model)
            if case .loading(_, let task) = removedState {
                task.cancel()
            }
            let stateRelease = DeferredStateRelease(removedState)
            Task.detached(priority: .utility) {
                stateRelease.release()
            }
            return
        }
        let cleanupURL: URL?
        AppLog.info("Local LLM delete actor entered model=\(model.repositoryID) path=\(cacheURL.path) exists=\(FileManager.default.fileExists(atPath: cacheURL.path)) state=\(modelStateDescription(for: model))")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            let moveStart = Self.now()
            let deletingURL = Self.deletingURL(for: cacheURL)
            AppLog.info("Scheduling local LLM model delete model=\(model.repositoryID) path=\(cacheURL.path) deletingPath=\(deletingURL.path)")
            try FileManager.default.moveItem(at: cacheURL, to: deletingURL)
            cleanupURL = deletingURL
            AppLog.info("Local LLM model cache detached model=\(model.repositoryID) move_ms=\(Self.milliseconds(since: moveStart))")
        } else {
            cleanupURL = nil
        }

        let removedState = states.removeValue(forKey: model)
        if case .loading(_, let task) = removedState {
            task.cancel()
        }
        let stateRelease = DeferredStateRelease(removedState)

        Task.detached(priority: .utility) {
            let unloadStart = Self.now()
            stateRelease.release()
            let unloadMilliseconds = Self.milliseconds(since: unloadStart)

            let removeStart = Self.now()
            do {
                if let cleanupURL, FileManager.default.fileExists(atPath: cleanupURL.path) {
                    try FileManager.default.removeItem(at: cleanupURL)
                }
                AppLog.info("Local LLM delete cleanup complete model=\(model.repositoryID) unload_ms=\(unloadMilliseconds) remove_cache_ms=\(Self.milliseconds(since: removeStart))")
            } catch {
                AppLog.error("Local LLM delete cleanup failed model=\(model.repositoryID) path=\(cleanupURL?.path ?? "none") unload_ms=\(unloadMilliseconds) remove_cache_ms=\(Self.milliseconds(since: removeStart)) error=\(error.localizedDescription)")
            }
        }

        AppLog.info("Local LLM delete returned model=\(model.repositoryID) schedule_ms=\(Self.milliseconds(since: scheduleStart))")
    }

    func retainOnly(_ model: LocalLLMModel, reason: String) {
        releaseCachedModels(except: model, reason: reason)
    }

    func releaseAll(reason: String) {
        let staleModels = Array(states.keys)
        guard !staleModels.isEmpty else { return }

        let releasedStates = staleModels.compactMap { staleModel -> DeferredStateRelease? in
            guard let removedState = states.removeValue(forKey: staleModel) else {
                return nil
            }
            if case .loading(_, let task) = removedState {
                task.cancel()
            }
            AppLog.info("Local LLM cached model released reason=\(reason) released=\(staleModel.repositoryID)")
            return DeferredStateRelease(removedState)
        }

        Task.detached(priority: .utility) {
            for releasedState in releasedStates {
                releasedState.release()
            }
        }
    }

    private func modelContainer(
        for model: LocalLLMModel,
        onProgress: ProgressHandler? = nil
    ) async throws -> ModelContainer {
        releaseCachedModels(except: model, reason: "activate")

        switch states[model] ?? .idle {
        case .idle:
            let loadID = UUID()
            let task = Task {
                try Task.checkCancellation()
                AppLog.info("Loading local LLM model=\(model.repositoryID)")
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: model.configuration,
                    progressHandler: { progress in
                        let fractionCompleted = progress.fractionCompleted
                        onProgress?(fractionCompleted)
                        let percent = Int(fractionCompleted * 100)
                        AppLog.info("Local LLM download model=\(model.repositoryID) progress=\(percent)% completed=\(progress.completedUnitCount) total=\(progress.totalUnitCount)")
                    }
                )
                try Task.checkCancellation()
                onProgress?(1)
                AppLog.info("Loaded local LLM model=\(model.repositoryID)")
                return container
            }
            states[model] = .loading(loadID, task)
            do {
                let container = try await task.value
                guard case .loading(let currentLoadID, _) = states[model],
                      currentLoadID == loadID
                else {
                    AppLog.info("Local LLM loaded obsolete model discarded model=\(model.repositoryID)")
                    throw CancellationError()
                }
                states[model] = .loaded(container)
                return container
            } catch {
                if case .loading(let currentLoadID, _) = states[model],
                   currentLoadID == loadID {
                    states.removeValue(forKey: model)
                }
                markRuntimeUnavailableIfNeeded(error)
                throw error
            }

        case .loading(_, let task):
            return try await task.value

        case .loaded(let container):
            return container
        }
    }

    private func modelStateDescription(for model: LocalLLMModel) -> String {
        switch states[model] ?? .idle {
        case .idle:
            "idle"
        case .loading:
            "loading"
        case .loaded:
            "loaded"
        }
    }

    private func releaseCachedModels(except retainedModel: LocalLLMModel, reason: String) {
        let staleModels = states.keys.filter { $0 != retainedModel }
        guard !staleModels.isEmpty else { return }

        let releasedStates = staleModels.compactMap { staleModel -> DeferredStateRelease? in
            guard let removedState = states.removeValue(forKey: staleModel) else {
                return nil
            }
            if case .loading(_, let task) = removedState {
                task.cancel()
            }
            AppLog.info("Local LLM cached model released reason=\(reason) retained=\(retainedModel.repositoryID) released=\(staleModel.repositoryID)")
            return DeferredStateRelease(removedState)
        }

        Task.detached(priority: .utility) {
            for releasedState in releasedStates {
                releasedState.release()
            }
        }
    }

    private func markRuntimeUnavailableIfNeeded(_ error: Error) {
        let description = String(describing: error)
        let localizedDescription = error.localizedDescription
        let combined = "\(description) \(localizedDescription)".lowercased()
        guard combined.contains("metallib")
            || combined.contains("metal library")
            || combined.contains("failed to load the default")
        else {
            return
        }

        runtimeUnavailableReason = localizedDescription
    }

    static var isCorrectionEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["DOUVO_LOCAL_LLM_POSTPROCESS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let value {
            return value != "0" && value != "false" && value != "off"
        }
        return LocalLLMSettingsStore.postProcessingEnabled
    }

    static var configuredModel: LocalLLMModel {
        let value = ProcessInfo.processInfo.environment["DOUVO_LOCAL_LLM_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalLLMModel(rawValue: value ?? "") ?? LocalLLMSettingsStore.selectedModel
    }

    private static var isEnabled: Bool {
        isCorrectionEnabled
    }

    static func correctionInstructions(
        for text: String,
        configuration: LocalLLMPromptConfiguration
    ) -> String {
        instructions(for: text, configuration: configuration)
    }

    static func correctionPrompt(
        for text: String,
        configuration: LocalLLMPromptConfiguration
    ) -> String {
        prompt(for: text, configuration: configuration)
    }

    static func fallbackCorrectionText(
        for rawText: String,
        vocabulary: String,
        punctuationStyle: PunctuationStyle
    ) -> String {
        fallbackText(for: rawText, vocabulary: vocabulary, punctuationStyle: punctuationStyle)
    }

    static func applyCorrectionVocabularyNormalizations(
        to text: String,
        vocabulary: String
    ) -> String {
        applyVocabularyNormalizations(to: text, vocabulary: vocabulary)
    }

    static func correctionVocabularyCandidates(
        for text: String,
        vocabulary: String
    ) -> [(source: String, target: String)] {
        correctionCandidates(in: text, vocabulary: vocabulary).map { candidate in
            (source: candidate.source, target: candidate.target)
        }
    }

    static func applyCorrectionPunctuationStyle(
        to text: String,
        style: PunctuationStyle
    ) -> String {
        applyPunctuationStyle(to: text, style: style)
    }

    static func cleanCorrectionResponse(_ response: String) -> String {
        cleanResponse(response)
    }

    private static func instructions(
        for text: String,
        configuration: LocalLLMPromptConfiguration
    ) -> String {
        let template = configuration.systemPromptTemplate
        let formattedVocabulary = formatVocabularyForPrompt(configuration.vocabulary, in: text)
        let punctuationStyle = configuration.punctuationStyle
        let rendered = renderPromptTemplate(
            template,
            original: text,
            formattedVocabulary: formattedVocabulary,
            punctuationStyle: punctuationStyle,
            removeFillerWords: configuration.removeFillerWords,
            softenEmotionalLanguage: configuration.softenEmotionalLanguage,
            outputStyleInstruction: configuration.outputStyleInstruction
        )
        guard !formattedVocabulary.isEmpty, !templateReferencesVocabulary(template) else {
            return rendered
        }
        return "\(rendered)\n\n\(vocabularyInstructionBlock(formattedVocabulary))"
    }

    private static func prompt(
        for text: String,
        configuration: LocalLLMPromptConfiguration
    ) -> String {
        let punctuationStyle = configuration.punctuationStyle
        return renderPromptTemplate(
            configuration.userPromptTemplate,
            original: text,
            formattedVocabulary: formatVocabularyForPrompt(configuration.vocabulary, in: text),
            punctuationStyle: punctuationStyle,
            removeFillerWords: configuration.removeFillerWords,
            softenEmotionalLanguage: configuration.softenEmotionalLanguage,
            outputStyleInstruction: configuration.outputStyleInstruction
        )
    }

    private static func renderPromptTemplate(
        _ template: String,
        original: String,
        formattedVocabulary: String,
        punctuationStyle: PunctuationStyle,
        removeFillerWords: Bool,
        softenEmotionalLanguage: Bool,
        outputStyleInstruction: String
    ) -> String {
        return PromptTemplateRenderer.render(
            template,
            values: [
                "original": original,
                "vocabularies": formattedVocabulary,
                "punctuation_style": punctuationStyle.promptValue,
                "punctuation_instruction": punctuationStyle.instruction,
                "remove_filler_words": removeFillerWords ? "true" : "",
                "soften_emotional_language": softenEmotionalLanguage ? "true" : "",
                "output_style_instruction": outputStyleInstruction
            ]
        )
    }

    private static func formatVocabularyForPrompt(_ vocabulary: String, in text: String) -> String {
        let candidates = correctionCandidates(in: text, vocabulary: vocabulary)
        guard !candidates.isEmpty else { return "" }
        return candidates
            .map { "- \($0.source) => \($0.target)" }
            .joined(separator: "\n")
    }

    private static func templateReferencesVocabulary(_ template: String) -> Bool {
        template.contains("vocabularies")
    }

    private static func vocabularyInstructionBlock(_ formattedVocabulary: String) -> String {
        """
        # 可能的识别错误候选
        以下映射只是候选，不一定全部正确；请结合上下文判断是否采用。采用时只替换左侧实际出现的片段，不要联想其它词库项。

        \(formattedVocabulary)
        """
    }

    private static func fallbackText(
        for rawText: String,
        vocabulary: String,
        punctuationStyle: PunctuationStyle
    ) -> String {
        let normalized = applyVocabularyNormalizations(to: rawText, vocabulary: vocabulary)
        return applyPunctuationStyle(to: normalized, style: punctuationStyle)
    }

    private static func applyVocabularyNormalizations(
        to text: String,
        vocabulary: String
    ) -> String {
        safeVocabularyCandidates(in: text, vocabulary: vocabulary).reduce(text) { output, candidate in
            output.replacingOccurrences(of: candidate.source, with: candidate.target)
        }
    }

    private static func correctionCandidates(in text: String, vocabulary: String) -> [VocabularyCandidate] {
        mergeCandidates(safeVocabularyCandidates(in: text, vocabulary: vocabulary) + hintVocabularyCandidates(in: text, vocabulary: vocabulary))
    }

    private struct VocabularyCandidate: Hashable {
        let source: String
        let target: String
    }

    private struct VocabularyCandidateKey: Hashable {
        let source: String
        let target: String
    }

    private static func safeVocabularyCandidates(in text: String, vocabulary: String) -> [VocabularyCandidate] {
        var candidates: [VocabularyCandidate] = []
        var seen = Set<VocabularyCandidateKey>()

        for phrase in vocabularyPhrases(from: vocabulary) {
            let matches: [String]
            if isCodeVocabularyPhrase(phrase) {
                matches = codeVocabularyMatches(for: phrase, in: text)
            } else if isLatinVocabularyPhrase(phrase) {
                matches = latinVocabularyMatches(for: phrase, in: text)
            } else if isChineseVocabularyPhrase(phrase) {
                matches = chineseVocabularyMatches(for: phrase, in: text)
            } else {
                matches = []
            }

            for match in matches where match != phrase {
                let key = VocabularyCandidateKey(source: match, target: phrase)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let candidate = VocabularyCandidate(source: match, target: phrase)
                candidates.append(candidate)
            }
        }

        return candidates
    }

    private static func hintVocabularyCandidates(in text: String, vocabulary: String) -> [VocabularyCandidate] {
        var candidates: [VocabularyCandidate] = []
        var seen = Set<VocabularyCandidateKey>()
        let safeKeys = Set(safeVocabularyCandidates(in: text, vocabulary: vocabulary).map {
            VocabularyCandidateKey(source: $0.source, target: $0.target)
        })

        for phrase in vocabularyPhrases(from: vocabulary) {
            guard isLatinHintVocabularyPhrase(phrase) else { continue }
            let matches = latinNearSoundMatches(for: phrase, in: text) + chineseTransliterationMatches(for: phrase, in: text)
            for match in matches where match != phrase {
                let key = VocabularyCandidateKey(source: match, target: phrase)
                guard !seen.contains(key), !safeKeys.contains(key) else { continue }
                seen.insert(key)
                candidates.append(VocabularyCandidate(source: match, target: phrase))
            }
        }

        return candidates
    }

    private static func mergeCandidates(_ candidates: [VocabularyCandidate]) -> [VocabularyCandidate] {
        var merged: [VocabularyCandidate] = []
        var seen = Set<VocabularyCandidateKey>()
        for candidate in candidates where candidate.source != candidate.target {
            let key = VocabularyCandidateKey(source: candidate.source, target: candidate.target)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(candidate)
        }
        return merged
    }

    private static func vocabularyPhrases(from vocabulary: String) -> [String] {
        var seen = Set<String>()
        return vocabulary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { phrase in
                let key = phrase.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    private static func isLatinVocabularyPhrase(_ phrase: String) -> Bool {
        phrase.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }

    private static func isCodeVocabularyPhrase(_ phrase: String) -> Bool {
        phrase.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        } && phrase.unicodeScalars.contains { scalar in
            codeVocabularySeparators.contains(Character(scalar))
        }
    }

    private static func isChineseVocabularyPhrase(_ phrase: String) -> Bool {
        phrase.count >= 2 && phrase.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isLatinHintVocabularyPhrase(_ phrase: String) -> Bool {
        var hasAlphanumeric = false
        for character in phrase {
            if character.isWhitespace { continue }
            guard isASCIIAlphanumeric(character) else { return false }
            hasAlphanumeric = true
        }
        return hasAlphanumeric
    }

    private static func codeVocabularyMatches(for phrase: String, in text: String) -> [String] {
        let targetKey = codeVocabularyKey(for: phrase)
        guard !targetKey.isEmpty else { return [] }

        let ranges = whitespaceTokenRanges(in: text)
        guard !ranges.isEmpty else { return [] }

        let maxWindow = max(phraseCodeComponentCount(phrase) * 3, 6)
        var matches: [String] = []
        for startIndex in ranges.indices {
            let endLimit = min(ranges.count - 1, startIndex + maxWindow - 1)
            for endIndex in startIndex...endLimit {
                let range = ranges[startIndex].lowerBound..<ranges[endIndex].upperBound
                let candidate = String(text[range])
                guard candidate != phrase,
                      codeVocabularyKey(for: candidate) == targetKey
                else {
                    continue
                }
                matches.append(candidate)
            }
        }
        return matches
    }

    private static func whitespaceTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func phraseCodeComponentCount(_ phrase: String) -> Int {
        phrase
            .split { character in
                !character.isLetter && !character.isNumber
            }
            .count
    }

    private static func codeVocabularyKey(for text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "点", with: "")
            .replacingOccurrences(of: "斜杠", with: "")
            .filter { character in
                character.isLetter || character.isNumber
            }
    }

    private static func latinVocabularyMatches(for phrase: String, in text: String) -> [String] {
        let pattern = phrase
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s_-]*")
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func latinNearSoundMatches(for phrase: String, in text: String) -> [String] {
        let phraseTokens = latinVocabularyTokens(in: phrase)
        guard !phraseTokens.isEmpty, phraseTokens.count <= 4 else { return [] }
        guard phraseTokens.count > 1 || (phraseTokens[0].count >= 5) else { return [] }
        let targetKeys = phraseTokens.map(doubleMetaphoneKeys(for:))
        guard targetKeys.allSatisfy({ !$0.isEmpty }) else { return [] }

        let ranges = latinTokenRanges(in: text)
        guard ranges.count >= phraseTokens.count else { return [] }

        var matches: [String] = []
        let windowSize = phraseTokens.count
        for startIndex in 0...(ranges.count - windowSize) {
            let endIndex = startIndex + windowSize - 1
            let range = ranges[startIndex].lowerBound..<ranges[endIndex].upperBound
            let candidate = String(text[range])
            let candidateTokens = latinVocabularyTokens(in: candidate)
            guard candidateTokens.count == phraseTokens.count,
                  latinComparableKey(for: candidateTokens) != latinComparableKey(for: phraseTokens),
                  doubleMetaphonePhraseMatches(candidateTokens, targetKeys: targetKeys)
            else {
                continue
            }
            matches.append(candidate)
        }
        return matches
    }

    private static func chineseTransliterationMatches(for phrase: String, in text: String) -> [String] {
        let phraseTokens = latinVocabularyTokens(in: phrase)
        guard phraseTokens.count == 1 else { return [] }

        let targetKey = englishTransliterationKey(for: phraseTokens[0])
        guard targetKey.count >= 4 else { return [] }

        let ranges = cjkTokenRanges(in: text)
        var matches: [String] = []
        for tokenRange in ranges {
            let token = String(text[tokenRange])
            let characters = Array(token)
            guard characters.count >= 2 else { continue }

            let maxWindow = min(4, characters.count)
            for windowSize in 2...maxWindow {
                guard windowSize <= characters.count else { continue }
                for startIndex in 0...(characters.count - windowSize) {
                    let candidate = String(characters[startIndex..<(startIndex + windowSize)])
                    let candidateKey = pinyinKey(for: candidate)
                    guard candidateKey.count >= 4,
                          isNearTransliteration(candidateKey, targetKey: targetKey)
                    else {
                        continue
                    }
                    matches.append(candidate)
                }
            }
        }
        return matches
    }

    private static func chineseVocabularyMatches(for phrase: String, in text: String) -> [String] {
        let phrasePinyin = pinyinKey(for: phrase)
        guard !phrasePinyin.isEmpty else { return [] }

        var matches: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let end = text.index(index, offsetBy: phrase.count, limitedBy: text.endIndex) else {
                break
            }

            let candidate = String(text[index..<end])
            if candidate != phrase,
               candidate.unicodeScalars.contains(where: isCJKScalar),
               isNearPinyin(candidate, phrasePinyin: phrasePinyin) {
                matches.append(candidate)
            }
            index = text.index(after: index)
        }
        return matches
    }

    private static func latinVocabularyTokens(in text: String) -> [String] {
        latinTokenRanges(in: text).map { range in
            String(text[range]).lowercased()
        }
    }

    private static func latinTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !isASCIIAlphanumeric(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, isASCIIAlphanumeric(text[index]) {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func cjkTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !text[index].unicodeScalars.contains(where: isCJKScalar) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, text[index].unicodeScalars.contains(where: isCJKScalar) {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func latinComparableKey(for tokens: [String]) -> String {
        tokens.joined().filter { isASCIIAlphanumeric($0) }
    }

    private static func englishTransliterationKey(for token: String) -> String {
        var key = token.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if key.hasSuffix("r"), key.count > 4 {
            key.removeLast()
        }
        return key
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "qu", with: "kw")
    }

    private static func doubleMetaphonePhraseMatches(
        _ candidateTokens: [String],
        targetKeys: [Set<String>]
    ) -> Bool {
        guard candidateTokens.count == targetKeys.count else { return false }
        for (candidateToken, targetTokenKeys) in zip(candidateTokens, targetKeys) {
            let candidateTokenKeys = doubleMetaphoneKeys(for: candidateToken)
            guard !candidateTokenKeys.isDisjoint(with: targetTokenKeys) else { return false }
        }
        return true
    }

    private static func doubleMetaphoneKeys(for token: String) -> Set<String> {
        let letters = Array(token.uppercased().filter { $0 >= "A" && $0 <= "Z" })
        guard !letters.isEmpty else { return [] }

        var output = ""
        var index = 0

        while index < letters.count {
            let character = letters[index]
            let previous = index > 0 ? letters[index - 1] : "\0"
            let next = index + 1 < letters.count ? letters[index + 1] : "\0"
            let next2 = index + 2 < letters.count ? letters[index + 2] : "\0"

            switch character {
            case "A", "E", "I", "O", "U", "Y":
                if index == 0 {
                    appendPhoneticCode("A", to: &output)
                }
                index += 1
            case "B":
                appendPhoneticCode("P", to: &output)
                index += next == "B" ? 2 : 1
            case "C":
                if next == "H" {
                    appendPhoneticCode("X", to: &output)
                    index += 2
                } else if next == "I", next2 == "A" {
                    appendPhoneticCode("X", to: &output)
                    index += 3
                } else if ["I", "E", "Y"].contains(next) {
                    appendPhoneticCode("S", to: &output)
                    index += 2
                } else {
                    appendPhoneticCode("K", to: &output)
                    index += ["C", "K", "Q"].contains(next) ? 2 : 1
                }
            case "D":
                if next == "G", ["I", "E", "Y"].contains(next2) {
                    appendPhoneticCode("J", to: &output)
                    index += 3
                } else {
                    appendPhoneticCode("T", to: &output)
                    index += next == "D" ? 2 : 1
                }
            case "F":
                appendPhoneticCode("F", to: &output)
                index += next == "F" ? 2 : 1
            case "G":
                if next == "H" {
                    if index > 0, isEnglishVowel(previous) {
                        index += 2
                    } else {
                        appendPhoneticCode("K", to: &output)
                        index += 2
                    }
                } else if next == "N" {
                    appendPhoneticCode("N", to: &output)
                    index += 2
                } else if ["I", "E", "Y"].contains(next) {
                    appendPhoneticCode("J", to: &output)
                    index += 2
                } else {
                    appendPhoneticCode("K", to: &output)
                    index += next == "G" ? 2 : 1
                }
            case "H":
                if (index == 0 || !isEnglishVowel(previous)), isEnglishVowel(next) {
                    appendPhoneticCode("H", to: &output)
                }
                index += 1
            case "J":
                appendPhoneticCode("J", to: &output)
                index += next == "J" ? 2 : 1
            case "K":
                if previous != "C" {
                    appendPhoneticCode("K", to: &output)
                }
                index += next == "K" ? 2 : 1
            case "L":
                appendPhoneticCode("L", to: &output)
                index += next == "L" ? 2 : 1
            case "M":
                appendPhoneticCode("M", to: &output)
                index += next == "M" ? 2 : 1
            case "N":
                appendPhoneticCode("N", to: &output)
                index += next == "N" ? 2 : 1
            case "P":
                if next == "H" {
                    appendPhoneticCode("F", to: &output)
                    index += 2
                } else {
                    appendPhoneticCode("P", to: &output)
                    index += next == "P" ? 2 : 1
                }
            case "Q":
                appendPhoneticCode("K", to: &output)
                index += next == "Q" ? 2 : 1
            case "R":
                appendPhoneticCode("R", to: &output)
                index += next == "R" ? 2 : 1
            case "S":
                if next == "H" {
                    appendPhoneticCode("X", to: &output)
                    index += 2
                } else if (next == "I" && ["A", "O"].contains(next2)) {
                    appendPhoneticCode("X", to: &output)
                    index += 3
                } else {
                    appendPhoneticCode("S", to: &output)
                    index += next == "S" ? 2 : 1
                }
            case "T":
                if next == "H" {
                    appendPhoneticCode("0", to: &output)
                    index += 2
                } else if next == "I", ["A", "O"].contains(next2) {
                    appendPhoneticCode("X", to: &output)
                    index += 3
                } else if next == "C", next2 == "H" {
                    index += 3
                } else {
                    appendPhoneticCode("T", to: &output)
                    index += next == "T" ? 2 : 1
                }
            case "V":
                appendPhoneticCode("F", to: &output)
                index += next == "V" ? 2 : 1
            case "W":
                if next == "R" {
                    index += 1
                } else {
                    if isEnglishVowel(next) {
                        appendPhoneticCode("W", to: &output)
                    }
                    index += 1
                }
            case "X":
                if index == 0 {
                    appendPhoneticCode("S", to: &output)
                } else {
                    appendPhoneticCode("K", to: &output)
                    appendPhoneticCode("S", to: &output)
                }
                index += 1
            case "Z":
                appendPhoneticCode("S", to: &output)
                index += next == "Z" ? 2 : 1
            default:
                index += 1
            }
        }

        return output.isEmpty ? [] : [output]
    }

    private static func appendPhoneticCode(_ code: String, to output: inout String) {
        guard output.last != code.last else { return }
        output.append(code)
    }

    private static func isEnglishVowel(_ character: Character) -> Bool {
        ["A", "E", "I", "O", "U", "Y"].contains(character)
    }

    private static func isNearTransliteration(_ candidateKey: String, targetKey: String) -> Bool {
        let distance = levenshteinDistance(candidateKey, targetKey)
        return distance <= max(1, targetKey.count / 5)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
    }

    private static func isNearPinyin(_ candidate: String, phrasePinyin: String) -> Bool {
        let candidatePinyin = pinyinKey(for: candidate)
        guard !candidatePinyin.isEmpty else { return false }
        let distance = levenshteinDistance(candidatePinyin, phrasePinyin)
        return distance <= max(1, phrasePinyin.count / 4)
    }

    private static func pinyinKey(for text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return String(mutable)
            .lowercased()
            .filter { character in
                character >= "a" && character <= "z"
            }
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            current[0] = leftIndex
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    private static func applyPunctuationStyle(
        to text: String,
        style: PunctuationStyle
    ) -> String {
        switch style {
        case .complete:
            return text
        case .omitFinal:
            return removeFinalPunctuation(from: text)
        case .spaces:
            return replacePunctuationWithSpaces(in: text)
        }
    }

    private static func removeFinalPunctuation(from text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = output.last, finalPunctuationCharacters.contains(last) {
            output.removeLast()
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private static func replacePunctuationWithSpaces(in text: String) -> String {
        let replaced = text.map { character in
            spaceReplacementPunctuationCharacters.contains(character) ? " " : String(character)
        }.joined()
        return replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cleanResponse(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let finalText = finalAnswerFromThinkingResponse(text) {
            text = finalText
        } else {
            while let start = text.range(of: "<think>"),
                  let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = stripCodeFence(text)
        text = stripFinalAnswerLabel(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finalAnswerFromThinkingResponse(_ response: String) -> String? {
        if let marker = response.range(
            of: "</think>",
            options: [.caseInsensitive, .backwards]
        ) {
            let finalText = response[marker.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return finalText.isEmpty ? nil : finalText
        }

        guard !containsUnclosedReasoning(response) else {
            return nil
        }

        for label in finalAnswerLabels {
            if let marker = response.range(
                of: label,
                options: [.caseInsensitive, .backwards]
            ) {
                let finalText = response[marker.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalText.isEmpty {
                    return finalText
                }
            }
        }

        return nil
    }

    private static func containsUnclosedReasoning(_ response: String) -> Bool {
        let lowercasedResponse = response.lowercased()
        return lowercasedResponse.contains("<think>")
            || lowercasedResponse.contains("thinking process:")
            || lowercasedResponse.contains("思考过程：")
            || lowercasedResponse.contains("思考:")
            || lowercasedResponse.contains("思考：")
    }

    private static func stripCodeFence(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else {
            return text
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2 {
            text = lines.dropFirst().joined(separator: "\n")
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFinalAnswerLabel(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in finalAnswerLabels {
            if text.range(of: label, options: [.caseInsensitive])?.lowerBound == text.startIndex {
                text.removeSubrange(text.startIndex..<text.index(text.startIndex, offsetBy: label.count))
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func isUsableCorrection(_ corrected: String, original: String) -> Bool {
        let output = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return false }
        guard output.count <= max(original.count * 3, original.count + 120) else { return false }

        let lowercasedOutput = output.lowercased()
        guard !blockedResponsePrefixes.contains(where: { lowercasedOutput.hasPrefix($0) }) else { return false }
        guard !blockedResponseFragments.contains(where: { lowercasedOutput.contains($0) }) else { return false }
        return true
    }

    private static let finalAnswerLabels = [
        "Final Answer:",
        "Final answer:",
        "Final:",
        "Answer:",
        "最终答案：",
        "最终答案:",
        "最终正文：",
        "最终正文:",
        "校正后：",
        "校正后:",
        "输出：",
        "输出:"
    ]

    private static let blockedResponsePrefixes = [
        "thinking process:",
        "thinking:",
        "思考过程：",
        "思考：",
        "分析：",
        "原文：",
        "最终文本：",
        "校正后："
    ]

    private static let blockedResponseFragments = [
        "<think>",
        "</think>",
        "thinking process:",
        "only output final body text",
        "analyze the request",
        "specific vocabulary list",
        "asr correction",
        "output format:",
        "只输出最终正文",
        "原始转写：",
        "高置信度",
        "中置信度"
    ]

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func deletingURL(for cacheURL: URL) -> URL {
        cacheURL
            .deletingLastPathComponent()
            .appendingPathComponent(".douvo-deleting-\(cacheURL.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    }

    private static let finalPunctuationCharacters = Set<Character>("。！？.!?")
    private static let spaceReplacementPunctuationCharacters = Set<Character>("。！？；，、：；!?;,")
    private static let codeVocabularySeparators = Set<Character>("./_-")
}

private enum PromptTemplateRenderer {
    static func render(_ template: String, values: [String: String]) -> String {
        var index = template.startIndex
        return renderSection(
            template,
            index: &index,
            values: values,
            stopTags: []
        ).output
    }

    private static func renderSection(
        _ template: String,
        index: inout String.Index,
        values: [String: String],
        stopTags: Set<String>
    ) -> (output: String, stopTag: String?) {
        var output = ""

        while index < template.endIndex {
            guard let openRange = template.range(of: "{{", range: index..<template.endIndex) else {
                output += String(template[index..<template.endIndex])
                index = template.endIndex
                return (output, nil)
            }

            output += String(template[index..<openRange.lowerBound])

            guard let closeRange = template.range(of: "}}", range: openRange.upperBound..<template.endIndex) else {
                output += String(template[openRange.lowerBound..<template.endIndex])
                index = template.endIndex
                return (output, nil)
            }

            let tag = template[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index = closeRange.upperBound

            if stopTags.contains(tag) {
                return (output, tag)
            }

            if tag.hasPrefix("#if ") {
                let variableName = String(tag.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trueBranch = renderSection(
                    template,
                    index: &index,
                    values: values,
                    stopTags: ["else", "/if"]
                )
                let falseBranch: String
                if trueBranch.stopTag == "else" {
                    falseBranch = renderSection(
                        template,
                        index: &index,
                        values: values,
                        stopTags: ["/if"]
                    ).output
                } else {
                    falseBranch = ""
                }

                output += isTruthy(values[variableName]) ? trueBranch.output : falseBranch
            } else if tag == "else" || tag == "/if" {
                continue
            } else {
                output += values[tag] ?? ""
            }
        }

        return (output, nil)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
