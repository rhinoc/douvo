import XCTest
@testable import Douvo

final class SelectionEditingPromptTests: XCTestCase {
    func testSelectionEditingPromptUsesSelectedTextAsEditTarget() {
        let configuration = promptConfiguration(selectedText: "This paragraph is too verbose.")

        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "make it shorter",
            configuration: configuration
        )
        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "make it shorter",
            configuration: configuration
        )

        XCTAssertTrue(instructions.contains("# 纠错"))
        XCTAssertTrue(instructions.contains("# 选区编辑"))
        XCTAssertTrue(instructions.contains("语音内容是编辑指令"))
        XCTAssertLessThan(
            instructions.range(of: "# 选区编辑")!.lowerBound,
            instructions.range(of: "# 输入清理")!.lowerBound
        )
        XCTAssertTrue(userPrompt.contains("选中文本："))
        XCTAssertTrue(userPrompt.contains("This paragraph is too verbose."))
        XCTAssertTrue(userPrompt.contains("语音编辑指令："))
        XCTAssertTrue(userPrompt.contains("make it shorter"))
        XCTAssertFalse(userPrompt.contains("原始转写："))
    }

    func testNormalPromptOmitsSelectionEditingBranch() {
        let configuration = promptConfiguration(selectedText: "")

        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "please update this",
            configuration: configuration
        )
        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "please update this",
            configuration: configuration
        )

        XCTAssertFalse(instructions.contains("# 选区编辑"))
        XCTAssertTrue(instructions.contains("# 纠错"))
        XCTAssertTrue(userPrompt.contains("原始转写："))
        XCTAssertFalse(userPrompt.contains("选中文本："))
    }

    func testTranslationPromptUsesTargetLanguage() {
        let configuration = promptConfiguration(
            selectedText: "",
            translationLanguage: "English (United States)"
        )

        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "今天下午三点开会",
            configuration: configuration
        )
        let userPrompt = LocalLLMPostProcessor.correctionPrompt(
            for: "今天下午三点开会",
            configuration: configuration
        )

        XCTAssertTrue(instructions.contains("# 翻译"))
        XCTAssertTrue(instructions.contains("翻译成English (United States)"))
        XCTAssertTrue(instructions.contains("URL、邮箱、文件路径、命令行片段和代码标识符按原样保留"))
        XCTAssertTrue(instructions.contains("夹用的英文、专名、产品名和技术术语不确定时保留原文"))
        XCTAssertTrue(instructions.contains("输入已经是English (United States)时，只删除明显口癖"))
        XCTAssertTrue(instructions.contains("输入是命令式时，照原意翻译"))
        XCTAssertFalse(instructions.contains("除非用户明确要求，不翻译"))
        XCTAssertTrue(userPrompt.contains("目标语言："))
        XCTAssertTrue(userPrompt.contains("English (United States)"))
        XCTAssertTrue(userPrompt.contains("只输出翻译为English (United States)后的正文："))
    }

    func testSelectedTextReaderAllowsFiveHundredCharacters() {
        let selection = String(repeating: "a", count: 500)

        XCTAssertEqual(
            SelectedTextReader.validate(selection),
            .text(selection)
        )
    }

    func testSelectedTextReaderRejectsMoreThanFiveHundredCharacters() {
        let selection = String(repeating: "a", count: 501)

        XCTAssertEqual(
            SelectedTextReader.validate(selection),
            .tooLong
        )
    }

    private func promptConfiguration(
        selectedText: String,
        translationLanguage: String = ""
    ) -> LocalLLMPromptConfiguration {
        LocalLLMPromptConfiguration(
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
            selectedText: selectedText,
            translationLanguage: translationLanguage
        )
    }
}
