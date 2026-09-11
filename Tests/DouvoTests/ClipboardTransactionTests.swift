import AppKit
import XCTest
@testable import Douvo

final class ClipboardTransactionTests: XCTestCase {
    func testTransactionRestoresAllOriginalPasteboardTypes() throws {
        let pasteboard = try makePasteboard()
        let originalItem = NSPasteboardItem()
        originalItem.setString("原始文本", forType: .string)
        originalItem.setString("<p>原始文本</p>", forType: .html)
        originalItem.setData(Data([0x01, 0x02, 0x03]), forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([originalItem]))

        let transaction = try XCTUnwrap(
            ClipboardTransaction.begin(text: "识别结果", in: pasteboard)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "识别结果")

        XCTAssertTrue(transaction.restoreIfUnchanged(in: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "原始文本")
        XCTAssertEqual(pasteboard.string(forType: .html), "<p>原始文本</p>")
        XCTAssertEqual(pasteboard.data(forType: .rtf), Data([0x01, 0x02, 0x03]))
    }

    func testTransactionDoesNotRestoreAfterUserChangesClipboard() throws {
        let pasteboard = try makePasteboard()
        pasteboard.setString("原始文本", forType: .string)

        let transaction = try XCTUnwrap(
            ClipboardTransaction.begin(text: "识别结果", in: pasteboard)
        )
        pasteboard.setString("用户刚复制的内容", forType: .string)

        XCTAssertFalse(transaction.restoreIfUnchanged(in: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "用户刚复制的内容")
    }

    func testSnapshotRestoreRequiresExpectedChangeCount() throws {
        let pasteboard = try makePasteboard()
        pasteboard.setString("原始文本", forType: .string)
        let snapshot = ClipboardPasteboardSnapshot(from: pasteboard)

        pasteboard.setString("用户内容", forType: .string)

        XCTAssertFalse(
            snapshot.restore(
                to: pasteboard,
                ifChangeCountIs: snapshot.changeCount,
                andStringIs: "原始文本"
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "用户内容")
    }

    private func makePasteboard() throws -> NSPasteboard {
        let name = NSPasteboard.Name("DouvoClipboardTransactionTests.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }
}
