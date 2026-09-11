import XCTest
@testable import Douvo

final class ASRLabCommandTests: XCTestCase {
    func testDemoAudioStoreFindsPackagedResourceBundleWithoutBundleModule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourceBundle = root.appendingPathComponent("Douvo_Douvo.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedURL = resourceBundle.appendingPathComponent("ASRDemo.aiff")
        try Data().write(to: expectedURL)

        XCTAssertEqual(try DemoAudioStore.url(searchRoots: [root]), expectedURL)
    }

    func testSingleProviderDemoPreservesOpeningError() {
        let error = TranscriptionSessionError(
            domain: "Douvo.AndroidASR",
            code: 3,
            localizedDescription: "concurrency quota exceeded"
        )

        XCTAssertEqual(
            ASRDemoDiagnosticRunner.singleProviderOpeningError(
                activeProviders: ["android"],
                openedProviders: [],
                errorsByProvider: ["android": error]
            )?.localizedDescription,
            "concurrency quota exceeded"
        )
    }

    func testOptionsDefaultToAndroidProvider() throws {
        let options = try ASRLabCommand.options(from: ["Douvo", "--asr-lab", "/tmp/test.aiff"])

        XCTAssertEqual(options.audioURL.path, "/tmp/test.aiff")
        XCTAssertEqual(options.selection, ASRProviderSelection(.android))
        XCTAssertEqual(options.context, "")
        XCTAssertEqual(options.vocabulary, "")
    }

    func testOptionsAcceptMultipleProviders() throws {
        let options = try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--providers", "web,android,bageshuo"
        ])

        XCTAssertEqual(options.selection, ASRProviderSelection([.web, .android, .bageshuo]))
    }

    func testOptionsMigrateLegacyMixProvider() throws {
        let options = try ASRLabCommand.options(from: [
            "Douvo", "--asr-lab", "/tmp/test.aiff", "--provider", "mix"
        ])

        XCTAssertEqual(options.selection, ASRProviderSelection([.web, .android]))
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
