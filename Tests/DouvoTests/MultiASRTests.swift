import XCTest
@testable import Douvo

final class MultiASRTests: XCTestCase {
    func testSelectionSupportsAnyNumberOfRoutes() {
        let selection = ASRProviderSelection([.web, .android, .bageshuo])

        XCTAssertEqual(selection.sortedProviders, [.web, .android, .bageshuo])
        XCTAssertTrue(selection.usesWebASR)
        XCTAssertTrue(selection.usesAndroidASR)
        XCTAssertTrue(selection.usesBageshuoASR)
        XCTAssertEqual(selection.activeProviderKeys, ["web", "android", "bageshuo"])
        XCTAssertTrue(selection.requiresAICorrection)
    }

    func testSelectionParserAcceptsCommaSeparatedRoutes() {
        XCTAssertEqual(
            ASRProviderSelection.parse("web, android, bageshuo"),
            ASRProviderSelection([.web, .android, .bageshuo])
        )
        XCTAssertEqual(
            ASRProviderSelection.parse("mix"),
            ASRProviderSelection([.web, .android])
        )
    }

    func testMultiCorrectionPromptIncludesEveryRecognitionResult() {
        let prompt = TranscriptionManager.multiCorrectionPromptText(providerTexts: [
            "web": "今天我们测试 Web 识别",
            "android": "今天我们测试安卓识别",
            "bageshuo": "今天我们测试叭哥说识别"
        ])

        XCTAssertTrue(prompt.contains("识别结果（Web）"))
        XCTAssertTrue(prompt.contains("识别结果（Android）"))
        XCTAssertTrue(prompt.contains("识别结果（\(ASRProvider.bageshuo.displayName)）"))
        XCTAssertTrue(prompt.contains("今天我们测试 Web 识别"))
        XCTAssertTrue(prompt.contains("今天我们测试安卓识别"))
        XCTAssertTrue(prompt.contains("今天我们测试叭哥说识别"))
        XCTAssertFalse(prompt.contains("双路"))
    }

    func testMultiPromptLeakIsRejectedAsCorrectionOutput() {
        let leakedOutput = "本次语音输入有多路 ASR 识别结果 请综合所有信号 多路内容可能有重叠 识别结果（Web）测试文本 识别结果（Android）测试文本"
        let original = TranscriptionManager.multiCorrectionPromptText(providerTexts: [
            "web": "测试文本",
            "android": "测试文本"
        ])

        XCTAssertFalse(LocalLLMPostProcessor.isUsableCorrection(leakedOutput, original: original))
    }

    func testProviderNamesCanBeLegitimateDictationText() {
        XCTAssertTrue(LocalLLMPostProcessor.isUsableCorrection(
            "我们现在测试 Doubao Web 这个渠道",
            original: "我们现在测试 Doubao Web 这个渠道"
        ))
        XCTAssertTrue(LocalLLMPostProcessor.isUsableCorrection(
            "识别结果一这个标题可以保留",
            original: "识别结果一这个标题可以保留"
        ))
    }

    func testEquivalentMultiRouteTranscriptsCanUseSingleCorrectionInput() {
        XCTAssertTrue(TranscriptionManager.areEquivalentTranscripts([
            "我们现在测试 Doubao Web",
            "我们现在测试 Doubao Web",
            "我们现在测试 Doubao Web"
        ]))
        XCTAssertTrue(TranscriptionManager.areEquivalentTranscripts([
            "我们现在测试 Doubao Web。",
            "我们 现在 测试 Doubao Web",
            "我们现在测试Doubao Web"
        ]))
        XCTAssertFalse(TranscriptionManager.areEquivalentTranscripts([
            "我们现在测试 Doubao Web",
            "我们现在测试 Doubao Android"
        ]))
    }
}
