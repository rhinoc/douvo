import XCTest
@testable import Douvo

final class TranscriptHistoryStoreTests: XCTestCase {
    func testRecordPersistsOnlyTheMostRecentTwentyTranscripts() throws {
        let suiteName = "TranscriptHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 1...25 {
            TranscriptHistoryStore.record("transcript \(index)", defaults: defaults)
        }

        XCTAssertEqual(
            TranscriptHistoryStore.load(defaults: defaults),
            (6...25).map { "transcript \($0)" }
        )
    }

    func testRecordTrimsWhitespaceAndIgnoresEmptyTranscripts() throws {
        let suiteName = "TranscriptHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptHistoryStore.record("  saved transcript\n", defaults: defaults)
        TranscriptHistoryStore.record("  \n", defaults: defaults)

        XCTAssertEqual(TranscriptHistoryStore.load(defaults: defaults), ["saved transcript"])
    }
}
