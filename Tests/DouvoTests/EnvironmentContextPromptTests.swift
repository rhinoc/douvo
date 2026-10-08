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

    func testActiveAppBundleIDEqualityConditionSelectsMatchingBranch() {
        let matchingConfiguration = LocalLLMPromptConfiguration(
            systemPromptTemplate: "{{#if active_app_bundle_id == \"com.microsoft.VSCode\"}}VS Code{{else}}Other{{/if}}",
            userPromptTemplate: "{{#if active_app_bundle_id == \"com.microsoft.VSCode\"}}VS Code{{else}}Other{{/if}}",
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: .original,
            outputStyleStrength: .medium,
            customOutputStyleInstruction: "",
            environmentContext: "frontmost_app: Visual Studio Code",
            activeAppBundleID: "com.microsoft.VSCode",
            userIdentity: "",
            selectedText: ""
        )

        XCTAssertEqual(
            LocalLLMPostProcessor.correctionInstructions(
                for: "text",
                configuration: matchingConfiguration
            ),
            "VS Code"
        )
        XCTAssertEqual(
            LocalLLMPostProcessor.correctionPrompt(
                for: "text",
                configuration: matchingConfiguration
            ),
            "VS Code"
        )

        let nonMatchingConfiguration = LocalLLMPromptConfiguration(
            systemPromptTemplate: matchingConfiguration.systemPromptTemplate,
            userPromptTemplate: matchingConfiguration.userPromptTemplate,
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: .original,
            outputStyleStrength: .medium,
            customOutputStyleInstruction: "",
            environmentContext: matchingConfiguration.environmentContext,
            activeAppBundleID: "com.apple.Notes",
            userIdentity: "",
            selectedText: ""
        )

        XCTAssertEqual(
            LocalLLMPostProcessor.correctionInstructions(
                for: "text",
                configuration: nonMatchingConfiguration
            ),
            "Other"
        )
    }
}
