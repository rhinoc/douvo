import Foundation

enum PromptLabCommand {
    static func configURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--prompt-lab"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(configURL: URL) async -> Int32 {
        do {
            let config = try PromptLabConfig.load(from: configURL)
            let outputURL = try await PromptLabRunner(config: config, configURL: configURL).run()
            progress("Prompt lab result: \(outputURL.path)")
            return 0
        } catch {
            fputs("Prompt lab failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

private struct PromptLabConfig: Decodable {
    let name: String?
    let model: String?
    let models: [String]?
    let runs: Int?
    let outputDirectory: String?
    let systemPrompt: String?
    let systemPromptFile: String?
    let userPrompt: String?
    let userPromptFile: String?
    let vocabulary: StringList
    let vocabularyFile: String?
    let punctuationStyle: String?
    let removeFillerWords: Bool?
    let softenEmotionalLanguage: Bool?
    let outputStyle: String?
    let outputStyleStrength: String?
    let reasoningMode: String?
    let maxTokens: Int?
    let inputs: [PromptLabInput]

    static func load(from url: URL) throws -> PromptLabConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PromptLabConfig.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case model
        case models
        case runs
        case outputDirectory
        case systemPrompt
        case systemPromptFile
        case userPrompt
        case userPromptFile
        case vocabulary
        case vocabularyFile
        case punctuationStyle
        case removeFillerWords
        case softenEmotionalLanguage
        case outputStyle
        case outputStyleStrength
        case reasoningMode
        case maxTokens
        case inputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        models = try container.decodeIfPresent([String].self, forKey: .models)
        runs = try container.decodeIfPresent(Int.self, forKey: .runs)
        outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        systemPromptFile = try container.decodeIfPresent(String.self, forKey: .systemPromptFile)
        userPrompt = try container.decodeIfPresent(String.self, forKey: .userPrompt)
        userPromptFile = try container.decodeIfPresent(String.self, forKey: .userPromptFile)
        vocabulary = try container.decodeIfPresent(StringList.self, forKey: .vocabulary) ?? StringList([])
        vocabularyFile = try container.decodeIfPresent(String.self, forKey: .vocabularyFile)
        punctuationStyle = try container.decodeIfPresent(String.self, forKey: .punctuationStyle)
        removeFillerWords = try container.decodeIfPresent(Bool.self, forKey: .removeFillerWords)
        softenEmotionalLanguage = try container.decodeIfPresent(Bool.self, forKey: .softenEmotionalLanguage)
        outputStyle = try container.decodeIfPresent(String.self, forKey: .outputStyle)
        outputStyleStrength = try container.decodeIfPresent(String.self, forKey: .outputStyleStrength)
        reasoningMode = try container.decodeIfPresent(String.self, forKey: .reasoningMode)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        inputs = try container.decode([PromptLabInput].self, forKey: .inputs)
    }
}

private struct StringList: Decodable {
    let values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            values = string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return
        }
        values = try container.decode([String].self)
    }
}

private struct PromptLabInput: Decodable {
    let id: String?
    let text: String
    let expected: String?
    let mustContain: StringList
    let mustNotContain: StringList
    let shouldChange: Bool?
    let allowFallback: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case expected
        case mustContain
        case mustNotContain
        case shouldChange
        case allowFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        expected = try container.decodeIfPresent(String.self, forKey: .expected)
        mustContain = try container.decodeIfPresent(StringList.self, forKey: .mustContain) ?? StringList([])
        mustNotContain = try container.decodeIfPresent(StringList.self, forKey: .mustNotContain) ?? StringList([])
        shouldChange = try container.decodeIfPresent(Bool.self, forKey: .shouldChange)
        allowFallback = try container.decodeIfPresent(Bool.self, forKey: .allowFallback)
    }
}

private struct PromptLabRunner {
    let config: PromptLabConfig
    let configURL: URL

    func run() async throws -> URL {
        let models = try resolvedModels()
        let promptConfiguration = try resolvedPromptConfiguration()
        let generationProfile = try resolvedGenerationProfile()
        let runs = max(config.runs ?? 1, 1)
        let startedAt = Date()
        var modelResults: [[String: Any]] = []
        let totalAttempts = models.count * config.inputs.count * runs
        var completedAttempts = 0

        progress("Prompt lab starting: \(models.count) model(s), \(config.inputs.count) input(s), \(runs) run(s), \(totalAttempts) total attempt(s).")

        for (modelIndex, model) in models.enumerated() {
            modelResults.append(try await runModel(
                model,
                promptConfiguration: promptConfiguration,
                generationProfile: generationProfile,
                runs: runs,
                modelIndex: modelIndex + 1,
                modelCount: models.count,
                completedAttempts: &completedAttempts,
                totalAttempts: totalAttempts
            ))
        }

        let payload: [String: Any] = [
            "name": config.name ?? "prompt-lab",
            "type": "prompt_lab",
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "models": modelResults,
            "runs": runs,
            "punctuation_style": promptConfiguration.punctuationStyle.rawValue,
            "remove_filler_words": promptConfiguration.removeFillerWords,
            "soften_emotional_language": promptConfiguration.softenEmotionalLanguage,
            "output_style": promptConfiguration.outputStyle.rawValue,
            "output_style_strength": promptConfiguration.outputStyleStrength.rawValue,
            "reasoning_mode": generationProfile.reasoningMode.rawValue,
            "max_tokens": generationProfile.maxTokens.map(String.init) ?? "unlimited",
            "vocabulary": promptConfiguration.vocabulary
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        ]
        return try write(payload)
    }

    private func runModel(
        _ model: LocalLLMModel,
        promptConfiguration: LocalLLMPromptConfiguration,
        generationProfile: LocalLLMGenerationProfile,
        runs: Int,
        modelIndex: Int,
        modelCount: Int,
        completedAttempts: inout Int,
        totalAttempts: Int
    ) async throws -> [String: Any] {
        var cases: [[String: Any]] = []
        var modelEvaluations: [PromptLabEvaluation] = []

        progress("Model \(modelIndex)/\(modelCount): \(model.displayName) (\(model.rawValue))")

        for (inputIndex, input) in config.inputs.enumerated() {
            var attempts: [[String: Any]] = []
            var evaluations: [PromptLabEvaluation] = []
            for runIndex in 1...runs {
                let progressPrefix = "\(completedAttempts + 1)/\(totalAttempts)"
                progress("[\(progressPrefix)] model \(modelIndex)/\(modelCount), input \(inputIndex + 1)/\(config.inputs.count), run \(runIndex)/\(runs): \(model.displayName) / \(input.id ?? input.text)")
                let started = ProcessInfo.processInfo.systemUptime
                let result = try await LocalLLMPostProcessor.shared.correctedTextWithTrace(
                    for: input.text,
                    model: model,
                    requiresEnabled: false,
                    promptConfiguration: promptConfiguration,
                    generationProfile: generationProfile,
                    savePromptSnapshot: false
                )
                let wallMilliseconds = Self.milliseconds(since: started)
                let promptLabOutput = Self.promptLabOutput(for: result)
                let evaluation = Self.evaluate(
                    input: input,
                    result: result,
                    promptLabOutput: promptLabOutput
                )
                evaluations.append(evaluation)
                modelEvaluations.append(evaluation)
                attempts.append([
                    "run": runIndex,
                    "wall_ms": wallMilliseconds,
                    "output": promptLabOutput as Any,
                    "app_output": result.text,
                    "used_fallback": Self.usedFallback(result),
                    "matches_expected": input.expected.map { promptLabOutput == $0 } as Any,
                    "evaluation": evaluation.payload,
                    "metadata": result.metadata,
                    "timings": result.timings.map(Self.payload(for:)),
                    "debug": [
                        "system_prompt": result.debugInfo.systemPrompt ?? "",
                        "user_prompt": result.debugInfo.userPrompt ?? "",
                        "raw_response": result.debugInfo.rawResponse ?? "",
                        "cleaned_response": result.debugInfo.cleanedResponse ?? ""
                    ]
                ])
                completedAttempts += 1
                progress("[\(completedAttempts)/\(totalAttempts)] done: \(promptLabOutput ?? "<no model output>") (\(wallMilliseconds) ms)")
            }

            cases.append([
                "id": input.id ?? input.text,
                "input": input.text,
                "expected": input.expected as Any,
                "must_contain": input.mustContain.values,
                "must_not_contain": input.mustNotContain.values,
                "should_change": input.shouldChange as Any,
                "allow_fallback": input.allowFallback as Any,
                "evaluation_summary": Self.evaluationSummary(evaluations),
                "attempts": attempts
            ])
        }

        return [
            "model": [
                "raw_value": model.rawValue,
                "display_name": model.displayName,
                "repository_id": model.repositoryID
            ],
            "evaluation_summary": Self.evaluationSummary(modelEvaluations),
            "cases": cases
        ]
    }

    private func resolvedPromptConfiguration() throws -> LocalLLMPromptConfiguration {
        let systemPrompt = try loadedText(
            inline: config.systemPrompt,
            file: config.systemPromptFile,
            fallback: LocalLLMSettingsStore.defaultSystemPrompt
        )
        let userPrompt = try loadedText(
            inline: config.userPrompt,
            file: config.userPromptFile,
            fallback: LocalLLMSettingsStore.defaultUserPromptTemplate
        )
        let vocabulary = try loadedVocabulary()
        let punctuationStyle = try resolvedPunctuationStyle()
        let outputStyle = try resolvedOutputStyle()
        let outputStyleStrength = try resolvedOutputStyleStrength()
        return LocalLLMPromptConfiguration(
            systemPromptTemplate: systemPrompt,
            userPromptTemplate: userPrompt,
            vocabulary: vocabulary,
            punctuationStyle: punctuationStyle,
            removeFillerWords: config.removeFillerWords ?? LocalLLMSettingsStore.removeFillerWords,
            softenEmotionalLanguage: config.softenEmotionalLanguage ?? LocalLLMSettingsStore.softenEmotionalLanguage,
            outputStyle: outputStyle,
            outputStyleStrength: outputStyleStrength
        )
    }

    private func resolvedGenerationProfile() throws -> LocalLLMGenerationProfile {
        let reasoningMode = try resolvedReasoningMode()
        return .promptLab(reasoningMode: reasoningMode, maxTokens: config.maxTokens)
    }

    private func resolvedReasoningMode() throws -> LocalLLMReasoningMode {
        guard let value = config.reasoningMode else {
            return .disabled
        }
        if let mode = LocalLLMReasoningMode(rawValue: value) {
            return mode
        }
        throw PromptLabError.invalidReasoningMode(value)
    }

    private func loadedVocabulary() throws -> String {
        if let vocabularyFile = config.vocabularyFile {
            let text = try String(contentsOf: resolvedURL(vocabularyFile), encoding: .utf8)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !config.vocabulary.values.isEmpty {
            return config.vocabulary.values.joined(separator: "\n")
        }
        return LocalLLMSettingsStore.vocabulary
    }

    private func loadedText(
        inline: String?,
        file: String?,
        fallback: String
    ) throws -> String {
        if let file {
            return try String(contentsOf: resolvedURL(file), encoding: .utf8)
        }
        return inline ?? fallback
    }

    private func resolvedModels() throws -> [LocalLLMModel] {
        let values = config.models ?? [config.model ?? LocalLLMSettingsStore.selectedModel.rawValue]
        return try values.map(resolvedModel)
    }

    private func resolvedModel(_ value: String) throws -> LocalLLMModel {
        if let model = LocalLLMModel(rawValue: value) {
            return model
        }
        if let model = LocalLLMModel.allCases.first(where: { $0.displayName.caseInsensitiveCompare(value) == .orderedSame }) {
            return model
        }
        let url = resolvedURL(value).standardizedFileURL
        if LocalLLMModel.isValidLocalModelDirectory(url) {
            return LocalLLMModel.localDirectory(
                id: "local:\(url.path)",
                displayName: url.lastPathComponent,
                path: url.path
            )
        }
        throw PromptLabError.invalidModel(value)
    }

    private func resolvedPunctuationStyle() throws -> PunctuationStyle {
        guard let value = config.punctuationStyle else {
            return LocalLLMSettingsStore.punctuationStyle
        }
        if let style = PunctuationStyle(rawValue: value) {
            return style
        }
        if let style = PunctuationStyle.allCases.first(where: { $0.displayName == value }) {
            return style
        }
        throw PromptLabError.invalidPunctuationStyle(value)
    }

    private func resolvedOutputStyle() throws -> LocalLLMOutputStyle {
        guard let value = config.outputStyle else {
            return LocalLLMSettingsStore.outputStyle
        }
        if let style = LocalLLMOutputStyle(rawValue: value) {
            return style
        }
        if let style = LocalLLMOutputStyle.allCases.first(where: { $0.displayName == value }) {
            return style
        }
        throw PromptLabError.invalidOutputStyle(value)
    }

    private func resolvedOutputStyleStrength() throws -> LocalLLMOutputStyleStrength {
        guard let value = config.outputStyleStrength else {
            return LocalLLMSettingsStore.outputStyleStrength
        }
        if let strength = LocalLLMOutputStyleStrength(rawValue: value) {
            return strength
        }
        if let strength = LocalLLMOutputStyleStrength.allCases.first(where: { $0.displayName == value }) {
            return strength
        }
        throw PromptLabError.invalidOutputStyleStrength(value)
    }

    private func write(_ payload: [String: Any]) throws -> URL {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw PromptLabError.invalidOutputPayload
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let directory = try outputDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(Self.timestamp())-prompt-lab.json")
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func outputDirectoryURL() throws -> URL {
        if let outputDirectory = config.outputDirectory {
            return resolvedURL(outputDirectory)
        }
        return AppLog.directoryURL.appendingPathComponent("PromptLab", isDirectory: true)
    }

    private func resolvedURL(_ path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return configURL.deletingLastPathComponent().appendingPathComponent(expandedPath)
    }

    private static func payload(for timing: TraceTiming) -> [String: Any] {
        [
            "name": timing.name,
            "duration_ms": timing.milliseconds,
            "metadata": timing.metadata
        ]
    }

    private static func evaluate(
        input: PromptLabInput,
        result: LocalLLMPostprocessResult,
        promptLabOutput: String?
    ) -> PromptLabEvaluation {
        let usedFallback = usedFallback(result)
        let evaluatedOutput = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPromptLabOutput = promptLabOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var checks: [[String: Any]] = []

        func appendCheck(
            name: String,
            passed: Bool,
            expected: Any? = nil,
            actual: Any? = nil
        ) {
            var payload: [String: Any] = [
                "name": name,
                "passed": passed
            ]
            if let expected {
                payload["expected"] = expected
            }
            if let actual {
                payload["actual"] = actual
            }
            checks.append(payload)
        }

        appendCheck(
            name: "has_app_output",
            passed: !evaluatedOutput.isEmpty,
            actual: evaluatedOutput
        )

        if let expected = input.expected {
            appendCheck(
                name: "matches_expected",
                passed: evaluatedOutput == expected,
                expected: expected,
                actual: evaluatedOutput
            )
        }

        if let shouldChange = input.shouldChange {
            let changed = evaluatedOutput != input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            appendCheck(
                name: "changed_from_input",
                passed: shouldChange == changed,
                expected: shouldChange,
                actual: changed
            )
        }

        let fallbackAllowed = input.allowFallback ?? true
        appendCheck(
            name: "fallback_allowed",
            passed: fallbackAllowed || !usedFallback,
            expected: fallbackAllowed,
            actual: usedFallback
        )

        for term in input.mustContain.values {
            appendCheck(
                name: "must_contain",
                passed: evaluatedOutput.contains(term),
                expected: term,
                actual: evaluatedOutput
            )
        }

        for term in input.mustNotContain.values {
            appendCheck(
                name: "must_not_contain",
                passed: !evaluatedOutput.contains(term),
                expected: term,
                actual: evaluatedOutput
            )
        }

        let passed = checks.allSatisfy { check in
            check["passed"] as? Bool == true
        }

        return PromptLabEvaluation(
            passed: passed,
            checks: checks,
            evaluatedOutput: evaluatedOutput,
            rawModelOutput: rawPromptLabOutput,
            usedFallback: usedFallback
        )
    }

    private static func evaluationSummary(_ evaluations: [PromptLabEvaluation]) -> [String: Any] {
        let total = evaluations.count
        let passed = evaluations.filter(\.passed).count
        let fallback = evaluations.filter(\.usedFallback).count
        return [
            "attempts": total,
            "passed": passed,
            "failed": total - passed,
            "pass_rate": total > 0 ? Double(passed) / Double(total) : 0,
            "fallback_attempts": fallback
        ]
    }

    private static func promptLabOutput(for result: LocalLLMPostprocessResult) -> String? {
        let cleanedResponse = result.debugInfo.cleanedResponse?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedResponse, !cleanedResponse.isEmpty {
            return cleanedResponse
        }

        let rawResponse = result.debugInfo.rawResponse?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawResponse, !rawResponse.isEmpty {
            return rawResponse
        }

        return nil
    }

    private static func usedFallback(_ result: LocalLLMPostprocessResult) -> Bool {
        switch result.metadata["outcome"] {
        case "failed", "skipped", "rejected":
            return true
        default:
            return false
        }
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

private struct PromptLabEvaluation {
    let passed: Bool
    let checks: [[String: Any]]
    let evaluatedOutput: String
    let rawModelOutput: String
    let usedFallback: Bool

    var payload: [String: Any] {
        [
            "passed": passed,
            "evaluated_output": evaluatedOutput,
            "raw_model_output": rawModelOutput,
            "used_fallback": usedFallback,
            "checks": checks
        ]
    }
}

private func progress(_ message: String) {
    fputs("\(message)\n", stderr)
    fflush(stderr)
}

private enum PromptLabError: LocalizedError {
    case invalidModel(String)
    case invalidPunctuationStyle(String)
    case invalidOutputStyle(String)
    case invalidOutputStyleStrength(String)
    case invalidReasoningMode(String)
    case invalidOutputPayload

    var errorDescription: String? {
        switch self {
        case .invalidModel(let value):
            return "Unknown model '\(value)'. Use one of: \(LocalLLMModel.allCases.map(\.rawValue).joined(separator: ", "))."
        case .invalidPunctuationStyle(let value):
            return "Unknown punctuationStyle '\(value)'. Use one of: \(PunctuationStyle.allCases.map(\.rawValue).joined(separator: ", "))."
        case .invalidOutputStyle(let value):
            return "Unknown outputStyle '\(value)'. Use one of: \(LocalLLMOutputStyle.allCases.map(\.rawValue).joined(separator: ", "))."
        case .invalidOutputStyleStrength(let value):
            return "Unknown outputStyleStrength '\(value)'. Use one of: \(LocalLLMOutputStyleStrength.allCases.map(\.rawValue).joined(separator: ", "))."
        case .invalidReasoningMode(let value):
            return "Unknown reasoningMode '\(value)'. Use one of: \(LocalLLMReasoningMode.allCases.map(\.rawValue).joined(separator: ", "))."
        case .invalidOutputPayload:
            return "Could not serialize prompt lab output."
        }
    }
}
