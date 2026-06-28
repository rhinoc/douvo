import XCTest
@testable import Douvo

final class OutputStylePromptTests: XCTestCase {
    func testOriginalAndBlankCustomOutputStylesDoNotInjectOutputStyleBlock() {
        XCTAssertFalse(renderedSystemPrompt(outputStyle: .original).contains(outputStyleMarker))
        XCTAssertFalse(renderedSystemPrompt(outputStyle: .custom).contains(outputStyleMarker))
        XCTAssertFalse(
            renderedSystemPrompt(
                outputStyle: .custom,
                customOutputStyleInstruction: "   \n  "
            ).contains(outputStyleMarker)
        )
    }

    func testNonEmptyOutputStylesInjectOutputStyleBlockIntoSystemPrompt() {
        XCTAssertTrue(renderedSystemPrompt(outputStyle: .natural).contains(outputStyleMarker))
        XCTAssertTrue(renderedSystemPrompt(outputStyle: .concise).contains(outputStyleMarker))
        XCTAssertTrue(renderedSystemPrompt(outputStyle: .structured).contains(outputStyleMarker))

        let customInstruction = "Translate to concise English and preserve code identifiers."
        let customPrompt = renderedSystemPrompt(
            outputStyle: .custom,
            customOutputStyleInstruction: customInstruction
        )
        XCTAssertTrue(customPrompt.contains(outputStyleMarker))
        XCTAssertTrue(customPrompt.contains(customInstruction))
    }

    func testOutputStyleInstructionStaysOutOfUserPrompt() {
        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "帮我整理一下登录页问题还有接口超时和 README",
            configuration: promptConfiguration(outputStyle: .structured)
        )

        XCTAssertFalse(userPrompt.contains("# 输出风格"))
        XCTAssertFalse(userPrompt.contains("output_style_instruction"))
    }

    func testNaturalAndConciseStyleInstructionsKeepDifferentBoundaries() {
        let natural = renderedSystemPrompt(outputStyle: .natural)
        let concise = renderedSystemPrompt(outputStyle: .concise)

        XCTAssertTrue(natural.contains(outputStyleMarker))
        XCTAssertTrue(natural.contains("不要改成短句风格"))
        XCTAssertFalse(natural.contains("短句优先"))
        XCTAssertFalse(natural.contains("压缩铺垫"))

        XCTAssertTrue(concise.contains(outputStyleMarker))
        XCTAssertTrue(concise.contains("短句优先"))
        XCTAssertTrue(concise.contains("压缩铺垫"))
    }

    private func promptConfiguration(
        outputStyle: LocalLLMOutputStyle,
        outputStyleStrength: LocalLLMOutputStyleStrength = .medium,
        customOutputStyleInstruction: String = ""
    ) -> LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
            systemPromptTemplate: LocalLLMSettingsStore.defaultSystemPrompt,
            userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: outputStyle,
            outputStyleStrength: outputStyleStrength,
            customOutputStyleInstruction: customOutputStyleInstruction,
            environmentContext: "",
            userIdentity: "",
            selectedText: ""
        )
    }

    private var outputStyleMarker: String {
        "STYLE_INSTRUCTION:"
    }

    private func renderedSystemPrompt(
        outputStyle: LocalLLMOutputStyle,
        customOutputStyleInstruction: String = ""
    ) -> String {
        LocalLLMPostProcessor.correctionInstructions(
            for: "你帮我看一下这个问题",
            configuration: LocalLLMPromptConfiguration(
                systemPromptTemplate: """
                BASE
                {{#if output_style_instruction}}
                \(outputStyleMarker)
                {{output_style_instruction}}
                {{/if}}
                END
                """,
                userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
                vocabulary: "",
                punctuationStyle: .complete,
                removeFillerWords: false,
                softenEmotionalLanguage: false,
                outputStyle: outputStyle,
                outputStyleStrength: .medium,
                customOutputStyleInstruction: customOutputStyleInstruction,
                environmentContext: "",
                userIdentity: "",
                selectedText: ""
            )
        )
    }
}
