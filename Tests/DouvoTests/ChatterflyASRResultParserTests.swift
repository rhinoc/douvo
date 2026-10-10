import Foundation
import XCTest
@testable import Douvo

final class ChatterflyASRResultParserTests: XCTestCase {
    func testFinalAlternativeIncludesWordsAfterLastPartial() throws {
        let partial = try parse(#"{"results":[{"alternatives":[{"transcript":"文件。"}]}]}"#)
        let final = try parse(#"{"results":[{"alternatives":[{"transcript":"文件上传完成。"}],"is_final":true}]}"#)

        XCTAssertEqual(partial.replacementText, "文件。")
        XCTAssertFalse(partial.isFinal)
        XCTAssertEqual(final.replacementText, "文件上传完成。")
        XCTAssertTrue(final.isFinal)
    }

    func testEnvelopeFinalFlagPreservesNestedTranscript() throws {
        let update = try parse(#"{"is_final":true,"results":[{"alternatives":[{"transcript":"识别完成。"}]}]}"#)

        XCTAssertEqual(update.replacementText, "识别完成。")
        XCTAssertTrue(update.isFinal)
    }

    func testFinalDirectTranscriptReplacesPartial() throws {
        let update = try parse(#"{"is_final":true,"transcript":"识别完成。"}"#)

        XCTAssertEqual(update.replacementText, "识别完成。")
        XCTAssertTrue(update.isFinal)
    }

    func testTextlessFinalMarkerPreservesAccumulatedText() throws {
        let update = try parse(#"{"is_final":true}"#)

        XCTAssertNil(update.replacementText)
        XCTAssertNil(update.stableTextDelta)
        XCTAssertNil(update.temporaryText)
        XCTAssertTrue(update.isFinal)
    }

    func testStableAndTemporaryFragmentsKeepDeltaSemantics() throws {
        let update = try parse(#"{"stable_result":"识别","temp_result":"完成","is_final":true}"#)

        XCTAssertEqual(update.stableTextDelta, "识别")
        XCTAssertEqual(update.temporaryText, "完成")
        XCTAssertNil(update.replacementText)
        XCTAssertTrue(update.isFinal)
    }

    func testFinalResultReplacesAccumulatedText() throws {
        let update = try parse(#"{"final_result":"识别完成。"}"#)

        XCTAssertEqual(update.replacementText, "识别完成。")
        XCTAssertTrue(update.isFinal)
    }

    private func parse(_ json: String) throws -> ChatterflyASRClient.RecognitionUpdate {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(ChatterflyASRClient.resultUpdate(from: object))
    }
}
