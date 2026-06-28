import XCTest
@testable import Douvo

final class UserIdentityPromptTests: XCTestCase {
    func testUserIdentityInjectsWhenPresent() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "帮我处理一下这个 draft",
            configuration: LocalLLMPromptConfiguration(
                systemPromptTemplate: LocalLLMSettingsStore.defaultSystemPrompt,
                userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
                vocabulary: "",
                punctuationStyle: .complete,
                removeFillerWords: false,
                softenEmotionalLanguage: false,
                outputStyle: .original,
                outputStyleStrength: .medium,
                customOutputStyleInstruction: "",
                environmentContext: "",
                userIdentity: "用户是文艺工作者，经常口述文学评论和出版相关内容。",
                selectedText: ""
            )
        )

        XCTAssertTrue(instructions.contains("# 用户身份"))
        XCTAssertTrue(instructions.contains("文艺工作者"))
        XCTAssertFalse(instructions.contains("user_identity"))
    }

    func testUserIdentityBlockIsOmittedWhenEmpty() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "帮我处理一下这个 draft",
            configuration: LocalLLMPromptConfiguration(
                systemPromptTemplate: LocalLLMSettingsStore.defaultSystemPrompt,
                userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
                vocabulary: "",
                punctuationStyle: .complete,
                removeFillerWords: false,
                softenEmotionalLanguage: false,
                outputStyle: .original,
                outputStyleStrength: .medium,
                customOutputStyleInstruction: "",
                environmentContext: "",
                userIdentity: "",
                selectedText: ""
            )
        )

        XCTAssertFalse(instructions.contains("# 用户身份"))
        XCTAssertFalse(instructions.contains("user_identity"))
    }

    func testIncrementalSystemPromptAppendsToEffectiveSystemPrompt() {
        let previousCustomSystemPrompt = LocalLLMSettingsStore.customSystemPrompt
        let previousIncrementalSystemPrompt = LocalLLMSettingsStore.incrementalSystemPrompt
        defer {
            LocalLLMSettingsStore.customSystemPrompt = previousCustomSystemPrompt
            LocalLLMSettingsStore.incrementalSystemPrompt = previousIncrementalSystemPrompt
        }

        LocalLLMSettingsStore.customSystemPrompt = "Base system prompt."
        LocalLLMSettingsStore.incrementalSystemPrompt = "Preserve publishing and literary terminology."

        let systemPrompt = LocalLLMSettingsStore.systemPrompt
        XCTAssertTrue(systemPrompt.contains("Base system prompt."))
        XCTAssertFalse(systemPrompt.contains("# 增量提示词"))
        XCTAssertTrue(systemPrompt.contains("Preserve publishing and literary terminology."))
        XCTAssertLessThan(
            systemPrompt.range(of: "Base system prompt.")!.lowerBound,
            systemPrompt.range(of: "Preserve publishing and literary terminology.")!.lowerBound
        )
    }
}
