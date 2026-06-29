import XCTest
@testable import Douvo

final class PunctuationStyleTests: XCTestCase {
    func testQuestionMarksOnlyStyleKeepsQuestionMarksAndRemovesOtherPunctuation() {
        let output = LocalLLMPostProcessor.applyCorrectionPunctuationStyle(
            to: "那现在会有问题吗？可以看一下，日志。OK!",
            style: .questionMarksOnly
        )

        XCTAssertEqual(output, "那现在会有问题吗？可以看一下 日志 OK")
    }

    func testQuestionMarksOnlyStylePreservesAsciiQuestionMarks() {
        let output = LocalLLMPostProcessor.applyCorrectionPunctuationStyle(
            to: "Can you check this? Then ship it.",
            style: .questionMarksOnly
        )

        XCTAssertEqual(output, "Can you check this? Then ship it")
    }

    func testQuestionMarksOnlyStylePreservesDotsInsideTechnicalTokens() {
        let output = LocalLLMPostProcessor.applyCorrectionPunctuationStyle(
            to: "检查 v1.2.3，example.com。然后继续?",
            style: .questionMarksOnly
        )

        XCTAssertEqual(output, "检查 v1.2.3 example.com 然后继续?")
    }

    func testQuestionMarksOnlyStylePromptIsConcise() {
        let previousLanguage = AppLanguageStore.selected
        AppLanguageStore.selected = .english
        defer {
            AppLanguageStore.selected = previousLanguage
        }

        XCTAssertEqual(PunctuationStyle.questionMarksOnly.displayName, "Question Marks Only")
        XCTAssertEqual(PunctuationStyle.questionMarksOnly.promptValue, "question_marks_only")
        XCTAssertTrue(PunctuationStyle.questionMarksOnly.instruction.contains("只保留问句的问号"))
    }
}
