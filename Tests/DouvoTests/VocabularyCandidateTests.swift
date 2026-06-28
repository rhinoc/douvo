import XCTest
@testable import Douvo

final class VocabularyCandidateTests: XCTestCase {
    func testCustomPromptWithoutVocabularyPlaceholderDoesNotAppendVocabularyBlock() {
        let configuration = LocalLLMPromptConfiguration(
            systemPromptTemplate: "只输出最终正文。",
            userPromptTemplate: LocalLLMSettingsStore.defaultUserPromptTemplate,
            vocabulary: "placeholder",
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

        let instructions = LocalLLMPostProcessor.correctionInstructions(
            for: "place holder",
            configuration: configuration
        )

        XCTAssertEqual(instructions, "只输出最终正文。")
        XCTAssertFalse(instructions.contains("place holder => placeholder"))
    }

    func testCodePathVocabularyMatchesSpokenPath() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "优化 sources D OUVO APP log 点 Swift 日志改为后台写入",
            vocabulary: "sources/douvo/applog.swift"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "sources D OUVO APP log 点 Swift"
                    && candidate.target == "sources/douvo/applog.swift"
            },
            "Expected spoken path to be mapped to the user-provided source path."
        )
    }

    func testJavaScriptPathVocabularyMatchesSpokenPathWithoutHardcodingExtension() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "把 packages web use auth 点 JS 里头的 fetch user profile 改成复用 cache key",
            vocabulary: "packages/web/useAuth.js"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "packages web use auth 点 JS"
                    && candidate.target == "packages/web/useAuth.js"
            },
            "Expected spoken JS path to be mapped from user vocabulary, not from built-in special cases."
        )
    }

    func testLatinVocabularyMatchesSplitAndCaseVariants() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "text area 里面 place HOLDER 好像有问题",
            vocabulary: """
            textarea
            placeholder
            """
        )

        XCTAssertTrue(candidates.contains { $0.source == "text area" && $0.target == "textarea" })
        XCTAssertTrue(candidates.contains { $0.source == "place HOLDER" && $0.target == "placeholder" })
    }

    func testChineseVocabularyMatchesNearPinyinCandidate() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "软件树枝叶里面有问题",
            vocabulary: "设置页"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "树枝叶" && candidate.target == "设置页"
            },
            "Expected near-pinyin Chinese ASR text to map to the user vocabulary phrase."
        )
    }

    func testChineseVocabularyDoesNotMatchSubstringInsideExactPhrase() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "合入之后的自动发版 workflow",
            vocabulary: "自动发版"
        )

        XCTAssertFalse(
            candidates.contains { candidate in
                candidate.source == "自动发" && candidate.target == "自动发版"
            },
            "Exact vocabulary phrases should not create nested substring corrections."
        )
    }

    func testChineseVocabularyMatchesExactPinyinHomophone() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "ASR result 和 message 日志也需要降品",
            vocabulary: "降频"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "降品" && candidate.target == "降频"
            },
            "Expected same-pinyin Chinese ASR text to map to the user vocabulary phrase."
        )
    }

    func testChineseVocabularyUsesPinyinNGramCandidate() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "需要把这个光线主权限加到项目里",
            vocabulary: "贡献者"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "光线主" && candidate.target == "贡献者"
            },
            "Expected Chinese pinyin n-gram matching to map the ASR phrase to the user vocabulary phrase."
        )
    }

    func testEnglishNearSoundVocabularyIsPromptCandidate() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "cloud code 这里的权限好像有问题",
            vocabulary: "Claude Code"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "cloud code" && candidate.target == "Claude Code"
            },
            "Expected near-sound English ASR text to be offered as an AI correction candidate."
        )
    }

    func testEnglishNearSoundVocabularyHandlesCommonPhoneticSpellings() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "fone number 和 nite mode 都需要重新检查",
            vocabulary: """
            phone
            night
            """
        )

        XCTAssertTrue(candidates.contains { $0.source == "fone" && $0.target == "phone" })
        XCTAssertTrue(candidates.contains { $0.source == "nite" && $0.target == "night" })
    }

    func testEnglishNearSoundDoesNotMatchShortSingleTokenVocabulary() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "cat 这里被误识别了",
            vocabulary: "code"
        )

        XCTAssertFalse(candidates.contains { $0.source == "cat" && $0.target == "code" })
    }

    func testChineseTransliterationVocabularyIsPromptCandidate() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "这个匹克里面的状态没有更新",
            vocabulary: "picker"
        )

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.source == "匹克" && candidate.target == "picker"
            },
            "Expected Chinese transliteration ASR text to be offered as an AI correction candidate."
        )
    }

    func testHintVocabularyCandidatesAreNotAppliedByFallback() {
        let text = "这个匹克里面 cloud code 有问题"
        let fallback = LocalLLMPostProcessor.fallbackCorrectionText(
            for: text,
            vocabulary: """
            picker
            Claude Code
            """,
            punctuationStyle: .complete
        )

        XCTAssertEqual(fallback, text)
    }

    func testSafeVocabularyCandidatesAreAppliedByFallback() {
        let fallback = LocalLLMPostProcessor.fallbackCorrectionText(
            for: "text area 里面 place HOLDER 好像有问题",
            vocabulary: """
            textarea
            placeholder
            """,
            punctuationStyle: .complete
        )

        XCTAssertEqual(fallback, "textarea 里面 placeholder 好像有问题")
    }

    func testChinesePinyinNGramVocabularyIsAppliedByFallback() {
        let fallback = LocalLLMPostProcessor.fallbackCorrectionText(
            for: "需要把这个光线主权限加到项目里",
            vocabulary: "贡献者",
            punctuationStyle: .complete
        )

        XCTAssertEqual(fallback, "需要把这个贡献者权限加到项目里")
    }

    func testDoesNotInventCandidatesWithoutVocabulary() {
        let candidates = LocalLLMPostProcessor.correctionVocabularyCandidates(
            for: "优化 sources D OUVO APP log 点 Swift 日志",
            vocabulary: ""
        )

        XCTAssertTrue(candidates.isEmpty)
    }
}
