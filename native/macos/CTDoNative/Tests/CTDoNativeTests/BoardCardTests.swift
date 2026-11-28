import XCTest
import NativeBridge
@testable import CTDoNative

final class BoardCardTests: XCTestCase {
    private func message(_ card: [String: Any]) throws -> MessageSnapshot {
        let source: [String: Any] = ["id": "n1", "timestamp": 1_000, "text": "Mừng ngày Văn hóa Việt Nam", "card": card]
        return try JSONDecoder().decode(MessageSnapshot.self, from: JSONSerialization.data(withJSONObject: source))
    }

    func testZaloNoticeKeepsHeaderAndChildRows() throws {
        let notice = try message(["kind": "board", "parts": [
            ["title": "Mừng ngày Văn hóa Việt Nam", "desc": "Cùng Zalo lan tỏa", "thumb": "https://example.invalid/h.jpg",
             "url": "https://example.invalid/a", "header": true],
            ["title": "Bài thứ hai", "desc": NSNull(), "thumb": NSNull(), "url": NSNull(), "header": false],
            ["title": "", "header": false],
        ]])
        let info = try XCTUnwrap(BoardCardInfo(notice))
        XCTAssertEqual(info.parts.count, 2)
        XCTAssertTrue(info.parts[0].header)
        XCTAssertEqual(info.parts[0].detail, "Cùng Zalo lan tỏa")
        XCTAssertNotNil(info.parts[0].thumbnail)
        XCTAssertNil(info.parts[1].url)
        XCTAssertFalse(NativeRowSupport.supports(notice))
    }

    func testOtherCardsAreNotBoards() throws {
        XCTAssertNil(BoardCardInfo(try message(["kind": "notice"])))
        XCTAssertNil(BoardCardInfo(try message(["kind": "board", "parts": []])))
    }
}
