import XCTest
@testable import Douvo

final class EnvironmentContextPromptTests: XCTestCase {
    func testEnvironmentContextInjectsWhenPresent() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "明天上午发给我",
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
                environmentContext: """
                current_time: 2026-06-28 12:30
                weekday: Sunday
                timezone: Asia/Singapore
                frontmost_app: Cursor
                """,
                userIdentity: "",
                selectedText: ""
            )
        )

        XCTAssertTrue(instructions.contains("# 当前环境"))
        XCTAssertTrue(instructions.contains("current_time: 2026-06-28 12:30"))
        XCTAssertTrue(instructions.contains("frontmost_app: Cursor"))
        XCTAssertFalse(instructions.contains("environment_context"))
    }

    func testEnvironmentContextBlockIsOmittedWhenEmpty() {
        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "明天上午发给我",
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

        XCTAssertFalse(instructions.contains("# 当前环境"))
        XCTAssertFalse(instructions.contains("environment_context"))
    }
}
