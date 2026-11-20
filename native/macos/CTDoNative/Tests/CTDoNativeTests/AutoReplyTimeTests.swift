import XCTest
@testable import CTDoNative

final class AutoReplyTimeTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!; return c }
    private let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 local

    func testWindowsAnchorAtYesterdayMidnightLikeZaloPC() {
        let midnight = Int64(calendar.startOfDay(for: now.addingTimeInterval(-86_400)).timeIntervalSince1970 * 1000)
        let lunch = AutoReplyTime.absolute(start: 43_200_000, end: 48_600_000, now: now, calendar: calendar)
        XCTAssertEqual(lunch.0, midnight + 43_200_000)
        XCTAssertEqual(lunch.1, midnight + 48_600_000)
        let overnight = AutoReplyTime.absolute(start: 64_800_000, end: 27_000_000, now: now, calendar: calendar)
        XCTAssertEqual(overnight.1, midnight + 27_000_000 + AutoReplyTime.day)
        let allDay = AutoReplyTime.absolute(start: 0, end: 0, now: now, calendar: calendar)
        XCTAssertEqual(allDay.1 - allDay.0, AutoReplyTime.day)
    }

    func testAbsoluteTimesReadBackAsTheSameWindow() {
        let overnight = AutoReplyTime.absolute(start: 64_800_000, end: 27_000_000, now: now, calendar: calendar)
        let back = AutoReplyTime.offsets(start: overnight.0, end: overnight.1, calendar: calendar)
        XCTAssertEqual(back.0, 64_800_000)
        XCTAssertEqual(back.1, 27_000_000)
        let allDay = AutoReplyTime.absolute(start: 0, end: 0, now: now, calendar: calendar)
        let day = AutoReplyTime.offsets(start: allDay.0, end: allDay.1, calendar: calendar)
        XCTAssertTrue(AutoReplyTime.isAllDay(day.0, day.1))
    }

    func testKeywordSettingsRoundTrip() {
        var settings = KeywordReplySettings()
        settings.enabled = true
        settings.rules = [KeywordReplyRule(id: "a", keyword: "giá", replyText: "Xem bảng giá ở đây")]
        let decoded = KeywordReplySettings(.object(settings.parameters))
        XCTAssertEqual(decoded, settings)
    }
}
