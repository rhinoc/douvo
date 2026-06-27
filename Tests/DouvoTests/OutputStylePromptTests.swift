import XCTest
@testable import Douvo

final class OutputStylePromptTests: XCTestCase {
    func testOriginalOutputStyleDoesNotInjectOutputStyleBlock() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "保留原文",
            configuration: promptConfiguration(outputStyle: .original, outputStyleStrength: .medium)
        )

        XCTAssertFalse(instructions.contains("# 输出风格"))
        XCTAssertFalse(instructions.contains("output_style_instruction"))
    }

    func testConciseOutputStyleInjectsStrengthSpecificInstruction() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "你帮我看一下这个问题 这个问题可能是因为配置不对",
            configuration: promptConfiguration(outputStyle: .concise, outputStyleStrength: .medium)
        )

        XCTAssertTrue(instructions.contains("# 输出风格"))
        XCTAssertTrue(instructions.contains("输出明显更简洁直接"))
        XCTAssertTrue(instructions.contains("短句优先"))
    }

    private func promptConfiguration(
        outputStyle: LocalLLMOutputStyle,
        outputStyleStrength: LocalLLMOutputStyleStrength
    ) -> LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
            systemPromptTemplate: LocalLLMSettingsStore.defaultSystemPrompt,
            userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: outputStyle,
            outputStyleStrength: outputStyleStrength
        )
    }
}
