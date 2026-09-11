import XCTest
@testable import Douvo

final class Spark2_5ModelTests: XCTestCase {
    func testSparkModelsAreBuiltInLocalModels() {
        let oneSevenB = LocalLLMModel.sparkX25OneSevenB
        let fourB = LocalLLMModel.sparkX25FourB

        XCTAssertTrue(LocalLLMModel.allCases.contains(oneSevenB))
        XCTAssertTrue(LocalLLMModel.allCases.contains(fourB))
        XCTAssertTrue(oneSevenB.isHuggingFaceModel)
        XCTAssertTrue(fourB.isHuggingFaceModel)
        XCTAssertTrue(oneSevenB.isSpark2_5)
        XCTAssertTrue(fourB.isSpark2_5)
        XCTAssertEqual(oneSevenB.repositoryID, "XHToken/Spark-X2.5-1.7B")
        XCTAssertEqual(fourB.repositoryID, "XHToken/Spark-X2.5-4B")
        XCTAssertEqual(oneSevenB.downloadSizeText, "3.4 GB")
        XCTAssertEqual(fourB.downloadSizeText, "8.2 GB")
    }

    func testSparkUsesTheGeneralDouvoPrompt() {
        let configuration = LocalLLMPromptConfiguration(
            systemPromptTemplate: "system {{original}}",
            userPromptTemplate: "user {{original}}",
            vocabulary: "",
            punctuationStyle: .complete,
            removeFillerWords: false,
            softenEmotionalLanguage: false,
            outputStyle: .original,
            outputStyleStrength: .medium,
            customOutputStyleInstruction: "",
            environmentContext: "",
            userIdentity: "",
            selectedText: "",
            translationLanguage: ""
        )

        XCTAssertEqual(
            LocalLLMPostProcessor.correctionInstructions(
                for: "hello",
                configuration: configuration,
                model: .sparkX25OneSevenB
            ),
            "system hello"
        )
        XCTAssertEqual(
            LocalLLMPostProcessor.correctionPrompt(
                for: "hello",
                configuration: configuration,
                model: .sparkX25OneSevenB
            ),
            "user hello"
        )
    }
}
