import XCTest
@testable import Douvo

final class ASRLabCommandTests: XCTestCase {
    func testOptionsDefaultToAndroidProvider() throws {
        let options = try ASRLabCommand.options(from: ["Douvo", "--asr-lab", "/tmp/test.aiff"])

        XCTAssertEqual(options.audioURL.path, "/tmp/test.aiff")
        XCTAssertEqual(options.provider, .android)
        XCTAssertEqual(options.context, "")
        XCTAssertEqual(options.vocabulary, "")
    }

    func testOptionsAcceptExplicitProvider() throws {
        let options = try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--provider", "mix"
        ])

        XCTAssertEqual(options.provider, .mix)
    }

    func testOptionsAcceptAndroidContext() throws {
        let options = try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--context", "worktree, FinishSession"
        ])

        XCTAssertEqual(options.context, "worktree, FinishSession")
    }

    func testOptionsAcceptPersonalLexiconVocabulary() throws {
        let options = try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--vocabulary", "textarea,Claude Code"
        ])

        XCTAssertEqual(options.vocabulary, "textarea,Claude Code")
    }

    func testOptionsRejectInvalidProvider() {
        XCTAssertThrowsError(try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--provider", "invalid"
        ]))
    }
}
