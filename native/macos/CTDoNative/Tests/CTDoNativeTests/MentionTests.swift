import XCTest
@testable import CTDoNative

final class MentionTests: XCTestCase {
    func testTaggedNamesAreRecognisedButEmailsAreNot() {
        XCTAssertTrue(MessageTypography.hasMention("Đề nghị @Lê Bá quay lại tắt quạt"))
        XCTAssertTrue(MessageTypography.hasMention("@All tất cả các bạn"))
        XCTAssertFalse(MessageTypography.hasMention("gửi vào it@anphat.vn nhé"))
        XCTAssertFalse(MessageTypography.hasMention("giá @ 20k"))
    }
    func testMentionIsStyledApartFromTheRest() {
        let styled = MessageTypography.withMentions("Nhờ @Thu Hương xem", outgoing: false)
        let tagged = styled.runs.filter { $0.foregroundColor != nil }.map { String(styled[$0.range].characters) }
        XCTAssertEqual(tagged, ["@Thu Hương"])
    }

    func testChosenTagsBecomeUTF16RangesAndEditedOnesAreDropped() {
        let chosen = [ComposerMention(uid: "111", name: "Hà Mây"), ComposerMention(uid: "-1", name: "All"),
                      ComposerMention(uid: "222", name: "Đã Xóa")]
        let ranges = ComposerAssistText.mentionRanges("Chào @Hà Mây 👋 @All nhé", chosen: chosen)
        XCTAssertEqual(ranges.map(\.uid), ["111", "-1"])
        XCTAssertEqual(ranges.map(\.pos), [5, 16])   // the emoji counts as two UTF-16 units
        XCTAssertEqual(ranges.map(\.len), [7, 4])
    }
    func testTheSameNameTaggedTwiceUsesBothPlaces() {
        let chosen = [ComposerMention(uid: "1", name: "An"), ComposerMention(uid: "1", name: "An")]
        XCTAssertEqual(ComposerAssistText.mentionRanges("@An và @An", chosen: chosen).map(\.pos), [0, 7])
    }
}
