import XCTest
@testable import Douvo

final class AndroidASRContextTests: XCTestCase {
    func testBuilderEncodesSharedContextAndVocabulary() throws {
        let snapshot = DictationContextSnapshot(
            environmentContext: "frontmost_app: Xcode",
            recentDictationContext: "上一条口述"
        )

        let encoded = AndroidASRContextBuilder.make(
            snapshot: snapshot,
            vocabulary: "Douvo\nSwift",
            includeContext: true,
            includeVocabularyHints: true,
            timestampMillis: 123
        )

        let contextData = try XCTUnwrap(Data(base64Encoded: encoded))
        let context = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contextData) as? [String: Any]
        )
        let chat = try XCTUnwrap(context["chat"] as? [[String: Any]])
        let entry = try XCTUnwrap(chat.first)
        let inputJSONString = try XCTUnwrap(entry["data"] as? String)
        let inputData = try XCTUnwrap(inputJSONString.data(using: .utf8))
        let input = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inputData) as? [String: Any]
        )
        let text = try XCTUnwrap(input["text"] as? String)

        XCTAssertEqual(
            text,
            "frontmost_app: Xcode\n\n上一条口述\n\nvocabulary: Douvo、Swift"
        )
        XCTAssertEqual(input["cursor_position"] as? Int, text.count)
        XCTAssertEqual(entry["time"] as? String, "123")
        XCTAssertEqual(entry["app_apk_name"] as? String, "com.android.chrome")
    }

    func testBuilderReturnsEmptyWhenNothingIsEnabled() {
        let encoded = AndroidASRContextBuilder.make(
            snapshot: DictationContextSnapshot(
                environmentContext: "frontmost_app: Xcode",
                recentDictationContext: "上一条口述"
            ),
            vocabulary: "Douvo",
            includeContext: false,
            includeVocabularyHints: false
        )

        XCTAssertTrue(encoded.isEmpty)
    }

    func testVocabularyHintIsDeduplicatedAndBounded() throws {
        let vocabulary = (["Douvo", "douvo"] + (1...60).map { "术语\($0)" })
            .joined(separator: "\n")

        let hint = try XCTUnwrap(AndroidASRContextBuilder.boundedVocabularyHint(from: vocabulary))
        let terms = hint.split(separator: "、").map(String.init)

        XCTAssertEqual(terms.first, "Douvo")
        XCTAssertEqual(terms.count, 50)
        XCTAssertLessThanOrEqual(hint.count, 500)
    }

    func testPromptConfigurationUsesSameContextSnapshot() {
        let snapshot = DictationContextSnapshot(
            environmentContext: "current_time: 2026-07-16 18:00",
            recentDictationContext: "上一条口述"
        )

        let configuration = LocalLLMPromptConfiguration.current.withContextSnapshot(snapshot)

        XCTAssertEqual(configuration.environmentContext, snapshot.environmentContext)
        XCTAssertEqual(configuration.recentDictationContext, snapshot.recentDictationContext)
    }
}
