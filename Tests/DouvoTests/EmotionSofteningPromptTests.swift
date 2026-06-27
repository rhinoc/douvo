import XCTest
@testable import Douvo

final class EmotionSofteningPromptTests: XCTestCase {
    func testEmotionSofteningDoesNotInjectWhenDisabled() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "我不同意这个观点",
            configuration: promptConfiguration(softenEmotionalLanguage: false)
        )

        XCTAssertFalse(instructions.contains("# 情绪弱化"))
        XCTAssertFalse(instructions.contains("soften_emotional_language"))
    }

    func testEmotionSofteningInjectsInstructionWhenEnabled() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "你这个观点就是放屁",
            configuration: promptConfiguration(softenEmotionalLanguage: true)
        )

        XCTAssertTrue(instructions.contains("# 情绪弱化"))
        XCTAssertTrue(instructions.contains("不要保留辱骂词"))
        XCTAssertTrue(instructions.contains("保留原本立场"))
    }

    private func promptConfiguration(softenEmotionalLanguage: Bool) -> LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
            systemPromptTemplate: LocalLLMSettingsStore.defaultSystemPrompt,
            userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: softenEmotionalLanguage,
            outputStyle: .original,
            outputStyleStrength: .medium
        )
    }
}
