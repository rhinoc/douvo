import XCTest
@testable import Douvo

final class S1MiniModelTests: XCTestCase {
    func testS1MiniIsAvailableAsBuiltInMLXModel() {
        let model = LocalLLMModel.s1Mini

        XCTAssertTrue(LocalLLMModel.allCases.contains(model))
        XCTAssertEqual(model.rawValue, "s1Mini")
        XCTAssertEqual(model.repositoryID, "mlx-community/S1-mini-MLX-4bit")
        XCTAssertEqual(model.downloadSizeText, "335 MB")
        XCTAssertTrue(model.isHuggingFaceModel)
        XCTAssertTrue(model.isS1Mini)
    }

    func testS1MiniUsesItsRequiredPromptFormat() {
        let configuration = LocalLLMPromptConfiguration(
            systemPromptTemplate: "custom system prompt",
            userPromptTemplate: "custom user prompt",
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: true,
            softenEmotionalLanguage: true,
            outputStyle: .concise,
            outputStyleStrength: .strong,
            customOutputStyleInstruction: "custom style",
            environmentContext: "frontmost_app: Notes",
            userIdentity: "software engineer",
            selectedText: "",
            translationLanguage: ""
        )

        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "so um send the report by friday",
            configuration: configuration,
            model: .s1Mini
        )
        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "so um send the report by friday",
            configuration: configuration,
            model: .s1Mini
        )

        XCTAssertEqual(
            instructions,
            "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
        )
        XCTAssertEqual(
            userPrompt,
            "[Styling: semi-formal] [Structure: prose] [Context: general]\nso um send the report by friday"
        )
    }

    func testS1MiniMapsDouvoOutputControlsToItsControlLine() {
        let configuration = LocalLLMPromptConfiguration(
            systemPromptTemplate: "",
            userPromptTemplate: "",
            vocabulary: "",
            punctuationStyle: .omitFinal,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: .structured,
            outputStyleStrength: .medium,
            customOutputStyleInstruction: "",
            environmentContext: "",
            userIdentity: "",
            selectedText: "",
            translationLanguage: ""
        )

        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "send the report and call Sarah",
            configuration: configuration,
            model: .s1Mini
        )

        XCTAssertEqual(
            userPrompt,
            "[Styling: semi-casual] [Structure: lists] [Context: general]\nsend the report and call Sarah"
        )
    }

    func testEmptyS1MiniOutputCanBeAcceptedForFillerOnlyInput() {
        XCTAssertFalse(
            LocalLLMPostProcessor.isUsableCorrection("", original: "um")
        )
        XCTAssertTrue(
            LocalLLMPostProcessor.isUsableCorrection("", original: "um", allowEmpty: true)
        )
    }
}
