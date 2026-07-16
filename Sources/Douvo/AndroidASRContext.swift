import Foundation

enum AndroidASRSettingsStore {
    private static let sendContextKey = "androidASR.sendContext"
    private static let sendVocabularyHintsKey = "androidASR.sendVocabularyHints"
    private static var defaults: UserDefaults { UserDefaults.standard }

    static var sendContext: Bool {
        get { defaults.bool(forKey: sendContextKey) }
        set { defaults.set(newValue, forKey: sendContextKey) }
    }

    static var sendVocabularyHints: Bool {
        get { defaults.bool(forKey: sendVocabularyHintsKey) }
        set { defaults.set(newValue, forKey: sendVocabularyHintsKey) }
    }
}

struct DictationContextSnapshot: Sendable, Equatable {
    let environmentContext: String
    let recentDictationContext: String

    static let empty = DictationContextSnapshot(
        environmentContext: "",
        recentDictationContext: ""
    )

    var androidText: String {
        [environmentContext, recentDictationContext]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

enum AndroidASRContextBuilder {
    private static let appName = "com.android.chrome"
    private static let maxVocabularyTerms = 50
    private static let maxVocabularyCharacters = 500

    static func make(
        snapshot: DictationContextSnapshot,
        vocabulary: String,
        includeContext: Bool,
        includeVocabularyHints: Bool,
        timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> String {
        var sections: [String] = []
        if includeContext, !snapshot.androidText.isEmpty {
            sections.append(snapshot.androidText)
        }
        if includeVocabularyHints,
           let vocabularyHint = boundedVocabularyHint(from: vocabulary) {
            sections.append("vocabulary: \(vocabularyHint)")
        }

        let text = sections.joined(separator: "\n\n")
        guard !text.isEmpty else { return "" }

        let inputData: [String: Any] = [
            "cursor_position": text.unicodeScalars.count,
            "text": text
        ]
        guard let inputJSON = try? JSONSerialization.data(withJSONObject: inputData),
              let inputJSONString = String(data: inputJSON, encoding: .utf8) else {
            return ""
        }

        let context: [String: Any] = [
            "chat": [[
                "type": "user_input",
                "data": inputJSONString,
                "time": String(timestampMillis),
                "app_apk_name": appName
            ]],
            "ime_info": [
                "app_apk_name": appName,
                "input_type": ""
            ]
        ]
        guard let contextJSON = try? JSONSerialization.data(withJSONObject: context) else {
            return ""
        }
        return contextJSON.base64EncodedString()
    }

    static func boundedVocabularyHint(from vocabulary: String) -> String? {
        var seen = Set<String>()
        var terms: [String] = []
        var characterCount = 0

        for rawTerm in vocabulary.split(whereSeparator: \.isNewline) {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }

            guard terms.count < maxVocabularyTerms else { break }
            let separatorCount = terms.isEmpty ? 0 : 1
            guard characterCount + separatorCount + term.count <= maxVocabularyCharacters else { continue }
            seen.insert(key)
            terms.append(term)
            characterCount += separatorCount + term.count
        }

        return terms.isEmpty ? nil : terms.joined(separator: "、")
    }
}

extension LocalLLMPromptConfiguration {
    func withContextSnapshot(_ snapshot: DictationContextSnapshot) -> LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
            systemPromptTemplate: systemPromptTemplate,
            userPromptTemplate: userPromptTemplate,
            vocabulary: vocabulary,
            punctuationStyle: punctuationStyle,
            removeFillerWords: removeFillerWords,
            softenEmotionalLanguage: softenEmotionalLanguage,
            outputStyle: outputStyle,
            outputStyleStrength: outputStyleStrength,
            customOutputStyleInstruction: customOutputStyleInstruction,
            environmentContext: snapshot.environmentContext,
            userIdentity: userIdentity,
            selectedText: selectedText,
            translationLanguage: translationLanguage,
            recentDictationContext: snapshot.recentDictationContext
        )
    }
}
