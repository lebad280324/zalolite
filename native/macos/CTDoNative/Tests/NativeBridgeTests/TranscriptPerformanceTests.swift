import XCTest
@testable import NativeBridge

final class TranscriptPerformanceTests: XCTestCase {
    private func fixture(_ count:Int) throws -> [MessageSnapshot] {
        var rows: [[String: Any]] = []
        for i in 0..<count {
            let timestamp: Int64 = 1_790_000_000_000 + Int64(i) * 1000
            let imageURL: Any = i % 2 == 0 ? "https://example.invalid/image.png" : NSNull()
            let row: [String: Any] = [
                "id": "message-\(i)",
                "text": "Synthetic example \(i)",
                "sender_id": "user-\(i / 3)",
                "sender_name": "Example",
                "timestamp": timestamp,
                "is_outgoing": i % 2 == 0,
                "image_url": imageURL
            ]
            rows.append(row)
        }
        return try JSONDecoder().decode([MessageSnapshot].self,from:JSONSerialization.data(withJSONObject:rows))
    }
    func testGroupingPreservesIdentityAndBoundaries() throws {
        let all=try fixture(20)
        let rows=TranscriptLayout.rows(all,mediaOnly:true)
        XCTAssertEqual(rows.map(\.id),all.filter{$0.imageURL != nil}.map(\.id))
        XCTAssertTrue(rows.first!.showsTimestamp);XCTAssertTrue(rows.first!.startsRun);XCTAssertTrue(rows.last!.endsRun)
        XCTAssertTrue(TranscriptLayout.rows([]).isEmpty)
    }
    func testLargeSnapshotIsPreparedBeforeMainActorAndRetainsQuoteChanges() throws {
        let encoded=try JSONSerialization.data(withJSONObject:["event":"messages","data":["thread_id":"one","messages":[["id":"a","text":"same","reply_to_text":"first"],["id":"a","text":"same","reply_to_text":"new"]]]])
        var event=try JSONDecoder().decode(CoreEvent.self,from:encoded);try event.prepareForUI()
        XCTAssertNil(event.data);XCTAssertEqual(event.preparedMessages?.messages.count,1)
        XCTAssertEqual(event.preparedMessages?.messages.first?.replyToText,"new")
        let a=try JSONDecoder().decode(MessageSnapshot.self,from:Data("{\"id\":\"one\",\"text\":\"same\",\"reply_to_text\":\"a\"}".utf8))
        let b=try JSONDecoder().decode(MessageSnapshot.self,from:Data("{\"id\":\"one\",\"text\":\"same\",\"reply_to_text\":\"b\"}".utf8))
        XCTAssertNotEqual(a,b)
    }
    func testMediaLayoutBenchmark() throws {
        let all=try fixture(2000)
        func ms(_ operation:()->Int)->(Double,Int){let start=DispatchTime.now().uptimeNanoseconds;let checksum=operation();return(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000,checksum)}
        var before:[Double]=[],after:[Double]=[]
        for _ in 0..<3 {
            let old=ms {
                func visible()->[MessageSnapshot]{all.filter{$0.imageURL != nil || $0.fileURL != nil}}
                var sum=0
                for i in visible().indices {
                    sum += visible()[i].id.count
                    if i>0 {sum += visible()[i-1].senderID.count}
                    if i+1<visible().count {sum += visible()[i+1].senderID.count}
                }
                return sum
            }
            let new=ms {TranscriptLayout.rows(all,mediaOnly:true).count}
            XCTAssertGreaterThan(old.1,0);XCTAssertEqual(new.1,1000)
            before.append(old.0);after.append(new.0)
        }
        print("TRANSCRIPT_BENCHMARK synthetic_messages=2000 mode=media before_median_ms=\(before.sorted()[1]) after_median_ms=\(after.sorted()[1])")
    }
}
