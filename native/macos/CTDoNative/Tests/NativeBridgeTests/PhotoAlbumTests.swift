import XCTest
@testable import NativeBridge

final class PhotoAlbumTests: XCTestCase {
    private func photo(_ id: String, group: String?, index: Int = 0, sender: String = "a", ts: Double = 1) throws -> MessageSnapshot {
        var fields: [String: Any] = ["id": id, "sender_id": sender, "msg_type": "chat.photo", "image_url": "https://photo.example.invalid/\(id).jpg", "timestamp": ts]
        if let group { fields["photo_group"] = ["group_id": group, "index": index, "total": 3] }
        return try JSONDecoder().decode(MessageSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testABatchBecomesOneRowInSentOrder() throws {
        let messages = [try photo("p2", group: "g", index: 2), try photo("p0", group: "g", index: 0),
                        try photo("p1", group: "g", index: 1), try photo("solo", group: nil)]
        let rows = TranscriptLayout.rows(messages)
        XCTAssertEqual(rows.map(\.id), ["p2", "solo"])
        XCTAssertEqual(rows[0].album.map(\.id), ["p0", "p1", "p2"])
        XCTAssertTrue(rows[1].album.isEmpty)
    }

    func testDifferentSendersOrBatchesStayApart() throws {
        let messages = [try photo("a1", group: "g"), try photo("b1", group: "g", sender: "b"), try photo("a2", group: "h")]
        XCTAssertEqual(TranscriptLayout.rows(messages).map(\.id), ["a1", "b1", "a2"])
    }
}
