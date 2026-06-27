import Foundation

enum PunctuationStyle: String, CaseIterable, Identifiable, Sendable {
    case complete
    case omitFinal
    case spaces

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .complete:
            "Complete Punctuation"
        case .omitFinal:
            "Omit Final Punctuation"
        case .spaces:
            "Use Spaces Instead"
        }
    }

    var promptValue: String {
        switch self {
        case .complete:
            "complete_punctuation"
        case .omitFinal:
            "omit_final_punctuation"
        case .spaces:
            "spaces_instead_of_punctuation"
        }
    }

    var instruction: String {
        switch self {
        case .complete:
            "添加自然、完整的标点和必要分句；句末需要标点时保留句末标点。"
        case .omitFinal:
            "添加必要的句中标点和分句，但最终输出末尾不要保留句号、问号、感叹号或英文句末标点。"
        case .spaces:
            "尽量不用标点表达停顿；需要分隔语义时用单个空格代替标点。不要破坏 URL、文件路径、版本号、代码、变量名或英文缩写。"
        }
    }
}

enum LocalLLMOutputStyle: String, CaseIterable, Identifiable, Sendable {
    case original
    case natural
    case concise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            "Original"
        case .natural:
            "Natural"
        case .concise:
            "Concise"
        }
    }

    func instruction(strength: LocalLLMOutputStyleStrength) -> String {
        switch self {
        case .original:
            ""
        case .natural:
            switch strength {
            case .light:
                "保持自然表达。只做轻微语序整理，让句子更顺；不要改变语气、信息或技术内容。"
            case .medium:
                "保持自然表达。可以适度压缩冗余表达和合并重复句；不要改变语气、信息或技术内容。"
            case .strong:
                "保持自然表达。更积极地压缩冗余表达和合并重复句；不要新增事实，不改变语气、信息或技术内容。"
            }
        case .concise:
            switch strength {
            case .light:
                "输出更简洁直接。删掉客套、弱表达和冗余措辞。"
            case .medium:
                "输出明显更简洁直接。压缩冗余表达、合并重复句，短句优先。"
            case .strong:
                "输出尽量简洁。积极压缩句子、合并重复表达、去掉客套和弱表达。"
            }
        }
    }
}

enum LocalLLMOutputStyleStrength: String, CaseIterable, Identifiable, Sendable {
    case light
    case medium
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:
            "Light"
        case .medium:
            "Medium"
        case .strong:
            "Strong"
        }
    }
}

enum LocalLLMSettingsStore {
    private enum Key {
        static let postProcessingEnabled = "localLLM.postProcessingEnabled"
        static let selectedModel = "localLLM.selectedModel"
        static let customModels = "localLLM.customModels"
        static let vocabulary = "localLLM.vocabulary"
        static let punctuationStyle = "localLLM.punctuationStyle"
        static let removeFillerWords = "localLLM.removeFillerWords"
        static let softenEmotionalLanguage = "localLLM.softenEmotionalLanguage"
        static let outputStyle = "localLLM.outputStyle"
        static let outputStyleStrength = "localLLM.outputStyleStrength"
        static let reasoningMode = "localLLM.reasoningMode"
        static let systemPrompt = "localLLM.systemPrompt"
        static let userPromptTemplate = "localLLM.userPromptTemplate"
    }

    static let defaultSystemPrompt = """
    你是 ASR 转写后处理器。

    # 输出要求
    - 只输出最终正文
    - 保持原文主要语言，不翻译
    - 不解释，不 Markdown，不输出标签或规则
    - 不新增事实，不扩写
    - 不改写已正确的代码、路径、URL、命令和专有名词

    {{#if vocabularies}}
    # 可能的识别错误候选
    - 下面是可能的 ASR 误识别映射；结合上下文采用
    - 只替换原文实际出现的左侧片段，不联想其它词库项

    {{vocabularies}}
    {{/if}}

    {{#if remove_filler_words}}
    # 口语整理
    - 删除不影响语义的填充词、犹豫词和口头自我修正
    - 只删口头停顿；真实顺序、强调、不确定含义要保留
    - 例：“嗯我就是想说先看一下” => “我先看一下”
    - 例：“可能说这个方案可以” => “这个方案可以”
    {{/if}}

    {{#if soften_emotional_language}}
    # 情绪弱化
    - 将辱骂、攻击性表达替换为文明克制表达；不要保留辱骂词
    - 保留原本立场、反对对象和核心诉求
    - 例：“你放屁” => “我不同意你的观点”
    - 例：“这是什么垃圾方案” => “这个方案不可取”
    {{/if}}

    # 纠错
    - 明显错词必须改；不确定就保留原文
    - 遇到语义不通的片段，按上下文做自我修正
    - 例：“他们的心也会倾向于不改” => “它们的行为也会倾向于不改”

    # 技术听写
    - 点（dot）-> .；杠（dash）-> -；斜杠（slash）-> /

    # 标点策略
    {{punctuation_instruction}}

    {{#if output_style_instruction}}
    # 输出风格
    {{output_style_instruction}}
    {{/if}}

    如果没有需要修改的内容，原样输出输入正文。
    """

    static let defaultUserPromptTemplate = """
    原始转写：
    {{original}}

    只输出最终正文：
    """

    private static let legacyXMLUserPromptTemplate = """
    下面是本次语音输入的原始 ASR 转写。请只按 system prompt 做纠错和最小整理，结果会被直接插入当前光标位置。

    <raw_transcript>
    {{original}}
    </raw_transcript>

    只输出最终文本正文。
    """

    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var postProcessingEnabled: Bool {
        get {
            defaults.bool(forKey: Key.postProcessingEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.postProcessingEnabled)
        }
    }

    static var selectedModel: LocalLLMModel {
        get {
            let value = defaults.string(forKey: Key.selectedModel)
            return LocalLLMModel(rawValue: value ?? "") ?? .quality
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.selectedModel)
            if CorrectionSettingsStore.backend == .local, !newValue.isDownloaded {
                defaults.set(false, forKey: Key.postProcessingEnabled)
            }
        }
    }

    static var vocabulary: String {
        get {
            defaults.string(forKey: Key.vocabulary) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Key.vocabulary)
        }
    }

    static var punctuationStyle: PunctuationStyle {
        get {
            let value = defaults.string(forKey: Key.punctuationStyle)
            return PunctuationStyle(rawValue: value ?? "") ?? .complete
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.punctuationStyle)
        }
    }

    static var removeFillerWords: Bool {
        get {
            defaults.bool(forKey: Key.removeFillerWords)
        }
        set {
            defaults.set(newValue, forKey: Key.removeFillerWords)
        }
    }

    static var softenEmotionalLanguage: Bool {
        get {
            defaults.bool(forKey: Key.softenEmotionalLanguage)
        }
        set {
            defaults.set(newValue, forKey: Key.softenEmotionalLanguage)
        }
    }

    static var outputStyle: LocalLLMOutputStyle {
        get {
            let value = defaults.string(forKey: Key.outputStyle)
            return LocalLLMOutputStyle(rawValue: value ?? "") ?? .original
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.outputStyle)
        }
    }

    static var outputStyleStrength: LocalLLMOutputStyleStrength {
        get {
            let value = defaults.string(forKey: Key.outputStyleStrength)
            return LocalLLMOutputStyleStrength(rawValue: value ?? "") ?? .medium
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.outputStyleStrength)
        }
    }

    static var reasoningMode: LocalLLMReasoningMode {
        get {
            let value = defaults.string(forKey: Key.reasoningMode)
            return LocalLLMReasoningMode(rawValue: value ?? "") ?? .disabled
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.reasoningMode)
        }
    }

    static var systemPrompt: String {
        get {
            let value = customSystemPrompt
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSystemPrompt : value
        }
        set {
            customSystemPrompt = newValue
        }
    }

    static var userPromptTemplate: String {
        get {
            let value = customUserPromptTemplate
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultUserPromptTemplate : value
        }
        set {
            customUserPromptTemplate = newValue
        }
    }

    static var customSystemPrompt: String {
        get {
            defaults.string(forKey: Key.systemPrompt) ?? ""
        }
        set {
            setCustomPromptValue(newValue, forKey: Key.systemPrompt)
        }
    }

    static var customUserPromptTemplate: String {
        get {
            let value = defaults.string(forKey: Key.userPromptTemplate) ?? ""
            if isLegacyXMLUserPromptTemplate(value) {
                defaults.removeObject(forKey: Key.userPromptTemplate)
                return ""
            }
            return value
        }
        set {
            setCustomPromptValue(newValue, forKey: Key.userPromptTemplate)
        }
    }

    static var canEnablePostProcessing: Bool {
        selectedModel.isDownloaded
    }

    static var customModels: [LocalLLMModel] {
        customModelRecords.map { record in
            LocalLLMModel.localDirectory(
                id: record.id,
                displayName: record.displayName,
                path: record.path
            )
        }
    }

    @discardableResult
    static func addCustomModelDirectory(_ url: URL) throws -> LocalLLMModel {
        let standardizedURL = url.standardizedFileURL
        guard LocalLLMModel.isValidLocalModelDirectory(standardizedURL) else {
            throw CustomModelError.invalidDirectory
        }

        let path = standardizedURL.path
        let id = "local:\(path)"
        let record = CustomLocalLLMModelRecord(
            id: id,
            displayName: standardizedURL.lastPathComponent,
            path: path
        )
        var records = customModelRecords.filter { $0.id != id && $0.path != path }
        records.append(record)
        customModelRecords = records
        return LocalLLMModel.localDirectory(
            id: record.id,
            displayName: record.displayName,
            path: record.path
        )
    }

    static func removeCustomModel(_ model: LocalLLMModel) {
        guard model.isLocalDirectoryModel else { return }
        let selectedRawValue = defaults.string(forKey: Key.selectedModel)
        customModelRecords = customModelRecords.filter { $0.id != model.rawValue }
        if selectedRawValue == model.rawValue {
            selectedModel = LocalLLMModel.allCases.first(where: { $0.isDownloaded }) ?? .quality
        }
    }

    private static func setCustomPromptValue(
        _ value: String,
        forKey key: String
    ) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
            return
        }

        defaults.set(value, forKey: key)
    }

    private static func isLegacyXMLUserPromptTemplate(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            == legacyXMLUserPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var customModelRecords: [CustomLocalLLMModelRecord] {
        get {
            guard let data = defaults.data(forKey: Key.customModels),
                  let records = try? JSONDecoder().decode([CustomLocalLLMModelRecord].self, from: data)
            else {
                return []
            }
            return records
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.customModels)
                return
            }
            defaults.set(data, forKey: Key.customModels)
        }
    }
}

private struct CustomLocalLLMModelRecord: Codable, Hashable {
    let id: String
    let displayName: String
    let path: String
}

enum CustomModelError: LocalizedError {
    case invalidDirectory

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "Choose an MLX model folder containing config.json, tokenizer files, and .safetensors weights."
        }
    }
}
