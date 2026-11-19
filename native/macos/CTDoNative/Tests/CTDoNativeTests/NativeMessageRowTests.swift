import XCTest
import SwiftUI
import NativeBridge
@testable import CTDoNative

final class NativeMessageRowTests: XCTestCase {
    @MainActor func testVisiblePhotosAlignToTheSameEdgeAsTextBubbles() throws {
        for outgoing in [false,true] {
            let photo = try rows([["id":"photo","timestamp":1_000,"text":"[Hình ảnh]",
                "is_outgoing":outgoing,"image_url":"https://example.invalid/photo.jpg"]])[0]
            let text = try rows([["id":"text","timestamp":1_000,"text":"Văn bản","is_outgoing":outgoing]])[0]
            for width:CGFloat in [240,420,820] {
                let layout = MessageRowLayout(input(photo),width:width)
                let textLayout = MessageRowLayout(input(text),width:width)
                let bounds = try XCTUnwrap(layout.photo).rect
                for size in [CGSize(width:300,height:600),CGSize(width:600,height:300),CGSize(width:400,height:400)] {
                    let rect = MessageMediaGeometry.fitted(size,in:bounds,outgoing:outgoing)
                    XCTAssertEqual(outgoing ? rect.maxX : rect.minX,outgoing ? textLayout.bubble.maxX : textLayout.bubble.minX,accuracy:0.01)
                    XCTAssertTrue(bounds.insetBy(dx:-0.01,dy:-0.01).contains(rect))
                    XCTAssertEqual(rect.width/rect.height,size.width/size.height,accuracy:0.01)
                }
            }
        }
    }

    @MainActor func testLongTextWrapsTallerWhenNarrowerAndStaysInsideTheRow() throws {
        let long = String(repeating: "Nội dung thử nghiệm bố trí tin nhắn khi thay đổi chiều rộng. ", count: 30)
        for outgoing in [false, true] {
            let row = try rows([["id": "long", "timestamp": 1_000, "text": long, "is_outgoing": outgoing, "sender_name": "Người gửi thử"]])[0]
            let wide = MessageRowLayout(input(row), width: 820), narrow = MessageRowLayout(input(row), width: 420)
            XCTAssertGreaterThan(narrow.height, wide.height)
            for layout in [wide, narrow] {
                let caption = try XCTUnwrap(layout.caption)
                XCTAssertTrue(layout.bubble.insetBy(dx: -0.5, dy: -0.5).contains(caption.rect), "text must not leave its bubble")
                XCTAssertTrue(layout.bubble.insetBy(dx: -0.5, dy: -0.5).contains(layout.timeRect), "time must not leave its bubble")
                XCTAssertGreaterThanOrEqual(layout.bubble.minX, 16)
                XCTAssertLessThanOrEqual(layout.bubble.maxX, layout.width - 16)
                XCTAssertLessThanOrEqual(layout.bubble.maxY, layout.height)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: layout.width, height: layout.height).contains(layout.ink))
                XCTAssertTrue(layout.ink.contains(layout.bubble))
                // Every line of the caption fits the width the bubble gives it.
                XCTAssertLessThanOrEqual(caption.block.lines.map(\.width).max() ?? 0, layout.bubble.width - 22 + 0.5)
            }
            XCTAssertEqual(wide.bubble.maxX, outgoing ? wide.width - 16 : wide.bubble.maxX)
        }
    }

    @MainActor func testBubbleAtItsWidthCapNeedsNoRedrawWhenOnlyTheRowWidens() throws {
        for outgoing in [false, true] {
            // The centered date pill moves relative to the bubble, so this case uses a row without one.
            let row = try rows([
                ["id": "previous", "timestamp": 1_790_000_000_000, "text": "Tin trước", "is_outgoing": outgoing],
                ["id": "short", "timestamp": 1_790_000_001_000, "text": "Tối thứ 6 tớ okie nhé!", "is_outgoing": outgoing]
            ])[1]
            XCTAssertFalse(row.showsTimestamp)
            let first = MessageRowLayout(input(row), width: 700), second = MessageRowLayout(input(row), width: 900)
            XCTAssertEqual(first.height, second.height)
            XCTAssertEqual(first.signature, second.signature, "a bubble that only slides sideways keeps its pixels")
            XCTAssertNotEqual(first.signature, MessageRowLayout(input(row), width: 240).signature)
        }
    }

    @MainActor func testCenteredDatePillInvalidatesDrawingWhenTheRowWidens() throws {
        let row = try rows([["id":"date","timestamp":1_000,"text":"Tin có nhãn ngày"]])[0]
        XCTAssertTrue(row.showsTimestamp)
        let first = MessageRowLayout(input(row),width:700),second = MessageRowLayout(input(row),width:900)
        XCTAssertNotEqual(first.signature,second.signature)
        XCTAssertEqual(first.height,second.height)
    }

    @MainActor func testPhotoQuoteReactionAndDatePillAreLaidOutWithoutOverlap() throws {
        let row = try rows([["id": "rich", "timestamp": 1_000, "text": "Chú thích dưới ảnh", "image_url": "https://example.invalid/a.jpg",
            "reply_to_id": "x", "reply_to_sender": "Người trả lời", "reply_to_text": "Nội dung được trả lời", "reactions": ["❤️"], "sender_name": "A"]])[0]
        let layout = MessageRowLayout(input(row, group: true), width: 640)
        let quote = try XCTUnwrap(layout.quote), photo = try XCTUnwrap(layout.photo), caption = try XCTUnwrap(layout.caption)
        XCTAssertNotNil(layout.pill, "the first message of a day carries the date")
        XCTAssertLessThanOrEqual(try XCTUnwrap(layout.pill).maxY, layout.bubble.minY)
        XCTAssertLessThanOrEqual(quote.rect.maxY, photo.rect.minY)
        XCTAssertLessThanOrEqual(photo.rect.maxY, caption.rect.minY)
        XCTAssertNotNil(layout.reactions)
        XCTAssertLessThanOrEqual(try XCTUnwrap(layout.reactions).maxY, layout.height)
        XCTAssertNotNil(layout.avatar)
        XCTAssertFalse(layout.bare)
        let bare = try rows([["id": "photo", "timestamp": 1_000, "text": "[Hình ảnh]", "image_url": "https://example.invalid/a.jpg"]])[0]
        XCTAssertTrue(MessageRowLayout(input(bare), width: 640).bare)
        XCTAssertNotNil(MessageRowLayout(input(bare), width: 640).timePill)
    }

    @MainActor func testStickersAndFilesKeepTheirSwiftUIRows() throws {
        let values = try rows([
            ["id": "s", "timestamp": 1_000, "msg_type": "chat.sticker", "image_url": "https://example.invalid/s.png"],
            ["id": "f", "timestamp": 2_000, "text": "Bao_cao.docx", "link_url": "https://example.invalid/Bao_cao.docx", "link_title": "Bao_cao.docx"],
            ["id": "t", "timestamp": 3_000, "text": "Văn bản"]])
        XCTAssertEqual(values.map { NativeRowSupport.supports($0.message) }, [false, false, true])
    }

    @MainActor func testPhotosStayInsideTheirBubblesAndRowsInNarrowWindows() throws {
        for outgoing in [false,true] {
            for caption in ["[Hình ảnh]","Chú thích bên dưới ảnh"] {
                let row = try rows([["id":"narrow-photo","timestamp":1_000,"text":caption,
                    "is_outgoing":outgoing,"image_url":"https://example.invalid/photo.jpg"]])[0]
                for width:CGFloat in [240,320,420,640] {
                    let layout = MessageRowLayout(input(row),width:width)
                    let photo = try XCTUnwrap(layout.photo).rect
                    XCTAssertTrue(layout.bubble.insetBy(dx:-0.5,dy:-0.5).contains(photo),"photo must fit its bubble at width \(width)")
                    XCTAssertGreaterThanOrEqual(photo.minX,16)
                    XCTAssertLessThanOrEqual(photo.maxX,width-16)
                    XCTAssertLessThanOrEqual(photo.maxY,layout.height)
                    if let text = layout.caption {XCTAssertLessThanOrEqual(photo.maxY,text.rect.minY)}
                }
            }
        }
    }

    @MainActor func testNativeRowsHaveExactHeightsOnScreenAndKeepTheReadingAnchorAcrossWidths() throws {
        _ = NSApplication.shared
        let model = TranscriptModel()
        let source: [[String: Any]] = (0..<300).map { index in
            ["id": "m-\(index)", "timestamp": 1_790_000_000_000 + index * 40_000, "is_outgoing": index % 3 == 0,
             "text": String(repeating: "Tin nhắn thử nghiệm số \(index) với nội dung đủ dài để xuống dòng. ", count: index % 7 + 1)]
        }
        model.activate("one", messages: try JSONDecoder().decode([MessageSnapshot].self, from: JSONSerialization.data(withJSONObject: source)))
        let parent = NativeTranscript(model: model, threadID: "one", rows: model.rows, jump: nil, configuration: 0,
            native: { self.input($0) }, content: { _ in AnyView(EmptyView()) }, loadMore: {}, loadNewer: {}, bottomChanged: { _ in })
        let coordinator = NativeTranscript.Coordinator(parent)
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        let table = NSTableView(frame: .zero)
        table.style = .fullWidth; table.intercellSpacing = .zero; table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.delegate = coordinator; table.dataSource = coordinator
        scroll.documentView = table; coordinator.table = table; coordinator.scroll = scroll

        coordinator.update(parent)
        XCTAssertEqual(coordinator.width, floor(scroll.contentView.bounds.width), "rows are laid out for the viewport, not for an unsized column")
        XCTAssertEqual(coordinator.diagnosticsVisibleMismatches(), [])
        XCTAssertTrue(try XCTUnwrap(coordinator.anchor()).bottom)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 120).minY + 9))
        coordinator.flushScroll()
        let before = try XCTUnwrap(coordinator.anchor())
        XCTAssertEqual(before.messageID, "m-120")
        XCTAssertEqual(coordinator.diagnosticsVisibleMismatches(), [])
        for width: CGFloat in [520, 430, 610, 760] {
            scroll.setFrameSize(NSSize(width: width, height: 480)); scroll.tile()
            coordinator.update(parent)
            let after = try XCTUnwrap(coordinator.anchor())
            XCTAssertEqual(after.messageID, before.messageID)
            XCTAssertEqual(after.offset, before.offset, accuracy: 1)
            XCTAssertEqual(coordinator.diagnosticsVisibleMismatches(), [], "no clipped or padded row at width \(width)")
        }
        coordinator.cancelPreparation()
    }

    @MainActor func testAnUnchangedCursorIsNotAppliedAgainWithinTheInterval() {
        CursorThrift.install()
        NSCursor.arrow.set()
        let now = CACurrentMediaTime()
        XCTAssertTrue(CursorThrift.isRedundant(.arrow, now: now))
        XCTAssertFalse(CursorThrift.isRedundant(.iBeam, now: now), "a different cursor always applies")
        XCTAssertFalse(CursorThrift.isRedundant(.arrow, now: now + CursorThrift.interval + 0.1), "the same cursor is re-applied after the interval")
        NSCursor.iBeam.set()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
        NSCursor.arrow.set()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    @MainActor private func input(_ row: TranscriptRow, group: Bool = false) -> NativeRowInput {
        NativeRowInput(row: row, isGroup: group, selecting: false, selected: false, highlighted: false, showThumbnails: true,
                       senderName: "", senderAvatar: nil, senderID: "", swipeOffset: 0)
    }

    private func rows(_ values: [[String: Any]]) throws -> [TranscriptRow] {
        TranscriptLayout.rows(try JSONDecoder().decode([MessageSnapshot].self, from: JSONSerialization.data(withJSONObject: values)))
    }

    func testAlbumRowsNeverLeaveASinglePhotoAlone() {
        for count in 2...12 {
            let rows = PhotoAlbumGrid.rowSizes(count)
            XCTAssertEqual(rows.reduce(0, +), count)
            XCTAssertTrue(rows.allSatisfy { (2...3).contains($0) }, "\(count): \(rows)")
        }
        XCTAssertEqual(PhotoAlbumGrid.rowSizes(4), [2, 2])
        XCTAssertEqual(PhotoAlbumGrid.rowSizes(5), [2, 3])
        XCTAssertEqual(PhotoAlbumGrid.rowSizes(7), [3, 2, 2])
    }
}
