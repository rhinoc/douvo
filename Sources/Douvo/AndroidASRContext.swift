import Foundation

enum AndroidASRSettingsStore {
    private static let sendContextKey = "androidASR.sendContext"
    private static let personalLexiconKey = "androidASR.sendVocabularyHints"
    private static var defaults: UserDefaults { UserDefaults.standard }

    static var sendContext: Bool {
        get { defaults.bool(forKey: sendContextKey) }
        set { defaults.set(newValue, forKey: sendContextKey) }
    }

    static var personalLexiconEnabled: Bool {
        get { defaults.bool(forKey: personalLexiconKey) }
        set { defaults.set(newValue, forKey: personalLexiconKey) }
    }
}

struct DictationContextSnapshot: Sendable, Equatable {
    let environmentContext: String
    let activeAppBundleID: String
    let recentDictationContext: String

    init(
        environmentContext: String,
        recentDictationContext: String,
        activeAppBundleID: String = ""
    ) {
        self.environmentContext = environmentContext
        self.activeAppBundleID = activeAppBundleID
        self.recentDictationContext = recentDictationContext
    }

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

    static func make(
        snapshot: DictationContextSnapshot,
        includeContext: Bool,
        timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> String {
        let text = includeContext ? snapshot.androidText : ""
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
            activeAppBundleID: snapshot.activeAppBundleID,
            userIdentity: userIdentity,
            selectedText: selectedText,
            translationLanguage: translationLanguage,
            recentDictationContext: snapshot.recentDictationContext
        )
    }
}
