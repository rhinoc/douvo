import Foundation
import XCTest
@testable import Douvo

final class DoubaoAndroidPersonalLexiconTests: XCTestCase {
    func testWordsNormalizeSupportedSeparatorsAndDeduplicateCaseInsensitively() {
        let words = DoubaoAndroidPersonalLexicon.words(
            from: " textarea\nREADME，claude Code、TEXTAREA; Codex； "
        )

        XCTAssertEqual(words, ["textarea", "README", "claude Code", "Codex"])
    }

    func testCacheTracksPerWordDigestsForEachDevice() throws {
        let suiteName = "DoubaoAndroidPersonalLexiconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let words = ["textarea", "Claude Code"]

        XCTAssertEqual(DoubaoAndroidPersonalLexicon.missingWords(
            words: words,
            deviceID: "device-a",
            defaults: defaults
        ), words)
        DoubaoAndroidPersonalLexicon.markUploaded(
            words: words,
            deviceID: "device-a",
            defaults: defaults
        )

        XCTAssertTrue(DoubaoAndroidPersonalLexicon.missingWords(
            words: words,
            deviceID: "device-a",
            defaults: defaults
        ).isEmpty)
        XCTAssertEqual(DoubaoAndroidPersonalLexicon.missingWords(
            words: words,
            deviceID: "device-b",
            defaults: defaults
        ), words)
        XCTAssertEqual(DoubaoAndroidPersonalLexicon.missingWords(
            words: ["textarea", "Claude code", "Codex"],
            deviceID: "device-a",
            defaults: defaults
        ), ["Claude code", "Codex"])
    }

    func testChaCha20MatchesRFC8439BlockVector() throws {
        let key = Data((0...31).map(UInt8.init))
        let nonce = try XCTUnwrap(Data(hex: "000000090000004a00000000"))
        let expected = try XCTUnwrap(Data(hex: """
        10f1e7e4d13b5915500fdd1fa32071c4
        c7d1f4c733c068030422aa9ac3d46c4e
        d2826446079faa0914c2d705d98b02a2
        b5129cd1de164eb9cbd083e8a2503c4e
        """))

        let actual = try DoubaoChaCha20.crypt(
            key: key,
            nonce: nonce,
            data: Data(repeating: 0, count: 64),
            initialCounter: 1
        )

        XCTAssertEqual(actual, expected)
    }
}

private extension Data {
    init?(hex: String) {
        let normalized = hex.filter { !$0.isWhitespace }
        guard normalized.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
