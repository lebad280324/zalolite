import XCTest
import AppKit
import Combine
import NativeBridge
@testable import CTDoNative

final class AppStoreTests: XCTestCase {
    private func event(_ source: String) throws -> CoreEvent { try JSONDecoder().decode(CoreEvent.self, from: Data(source.utf8)) }

    func testLateHistorySearchCannotReplaceNewerQueryOrClear() async throws {
        let reply = try event("""
        {"id":"placeholder","event":"result","command":"search_history","ok":true,"data":{"items":[{"thread_id":"thread-1","message":{"id":"message-1","text":"Old match","sender_name":"Example","timestamp":1,"is_outgoing":false,"msg_type":"chat.text"}}]}}
        """)
        await MainActor.run {
            let store=AppStore(arguments:["test","--demo"]);defer{store.stop()}
            store.ready=true;store.capabilities=["search_history"]
            store.searchHistory("old",onlyCurrentThread:false)
            let old=store.historySearchRequestID
            store.searchHistory("new",onlyCurrentThread:false,filesOnly:true)
            var response=reply;response.id=old;store.receive(response)
            XCTAssertTrue(store.historyResults.isEmpty)
            let latest=store.historySearchRequestID
            store.searchHistory("",onlyCurrentThread:false)
            response.id=latest;store.receive(response)
            XCTAssertTrue(store.historyResults.isEmpty)
        }
    }

    func testSendFailureRetainsDraftAndSuccessDoesNotEraseNewerEdits() async throws {
        let failure = try event("""
        {"id":"placeholder","event":"result","command":"send_message","ok":false,"error":"Chưa gửi được tin nhắn."}
        """)
        let success = try event("""
        {"id":"placeholder","event":"result","command":"send_message","ok":true,"data":{}}
        """)
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.ready = true; store.draft = "Bản nháp ban đầu"
            store.selectedThreadID = "thread-1"
            let id = store.send("send_message", threadID: "thread-1", submittedText: store.draft)
            var rejected = failure; rejected.id = id
            store.receive(rejected)
            XCTAssertEqual(store.draft, "Bản nháp ban đầu")
            XCTAssertFalse(store.busy.contains("send_message"))
            let secondID = store.send("send_message", threadID: "thread-1", submittedText: store.draft)
            store.draft = "Nội dung vừa sửa"
            var accepted = success; accepted.id = secondID
            store.receive(accepted)
            XCTAssertEqual(store.draft, "Nội dung vừa sửa")
            store.draft = "Nội dung đã gửi"
            let thirdID = store.send("send_message", threadID: "thread-1", submittedText: store.draft)
            accepted.id = thirdID
            store.receive(accepted)
            XCTAssertTrue(store.draft.isEmpty)
        }
    }

    func testOverlongDraftIsRejectedBeforeCreatingPendingSend() async throws {
        let thread = try JSONDecoder().decode(ThreadSnapshot.self, from: Data("""
        {"id":"thread-1","name":"Nhóm thử","is_group":true}
        """.utf8))
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.session = SessionSnapshot(loggedIn: true, uin: "user-1", name: "Người dùng thử")
            store.ready = true; store.capabilities = ["send_message"]
            store.threads = [thread]; store.selectedThreadID = thread.id
            store.draft = String(repeating: "Đ", count: 10_001)
            store.sendText()
            XCTAssertFalse(store.busy.contains("send_message"))
            XCTAssertNotNil(store.error)
            XCTAssertEqual(store.draft.count, 10_001)
        }
    }

    func testAccountChangeClearsDraftsBeforeShowingAnotherAccount() async throws {
        let account = try event("""
        {"event":"session","data":{"logged_in":true,"uin":"user-2","name":"Người dùng thử thứ hai"}}
        """)
        let thread = try JSONDecoder().decode(ThreadSnapshot.self, from: Data("""
        {"id":"thread-1","name":"Nhóm thử","is_group":true}
        """.utf8))
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.session = SessionSnapshot(loggedIn: true, uin: "user-1", name: "Người dùng thử")
            store.threads = [thread]; store.selectThread(thread.id)
            store.draft = "Nội dung riêng của user-1"; store.selectThread(nil)
            store.receive(account)
            store.threads = [thread]; store.selectThread(thread.id)
            XCTAssertTrue(store.draft.isEmpty)
            XCTAssertTrue(store.selectedMessages.isEmpty)
        }
    }

    func testRepeatedMessageIDsAreReconciledWithoutDuplicatingRows() async throws {
        let snapshot = try event("""
        {"event":"messages","data":{"thread_id":"thread-1","messages":[{"id":"msg-1","text":"Bản cũ","timestamp":1},{"id":"msg-1","text":"Bản mới","timestamp":1}]}}
        """)
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.receive(snapshot)
            XCTAssertEqual(store.messages["thread-1"]?.count, 1)
            XCTAssertEqual(store.messages["thread-1"]?.first?.text, "Bản mới")
        }
    }
    func testNewSnapshotClearsObsoleteSelectionAndLateReadError() async throws {
        let old = try JSONDecoder().decode(ThreadSnapshot.self, from: Data("{\"id\":\"old-thread\",\"name\":\"Nhóm thử\",\"is_group\":true,\"last_message_ts\":1000}".utf8))
        let refreshed = try event("{\"event\":\"threads\",\"data\":[{\"id\":\"current-thread\",\"name\":\"Nhóm thử\",\"is_group\":true,\"last_message_ts\":1000}]}")
        var failed = try event("{\"event\":\"result\",\"command\":\"load_messages\",\"ok\":false,\"error\":\"Hội thoại đã thay đổi\"}")
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.ready = true; store.threads = [old]; store.selectedThreadID = old.id
            let request = store.send("load_messages", threadID: old.id)
            store.receive(refreshed)
            XCTAssertNotEqual(store.selectedThreadID, old.id)
            failed.id = request; store.receive(failed)
            XCTAssertNil(store.error)
            XCTAssertNotNil(store.selectedThread)
        }
    }

    func testSearchAndUnreadFiltersPreserveServerThreadIdentity() async throws {
        let rows = try event("{\"event\":\"threads\",\"data\":[{\"id\":\"one\",\"name\":\"An Phát\",\"unread\":2,\"last_message_ts\":1000},{\"id\":\"two\",\"name\":\"Nhóm dự án\",\"is_group\":true,\"last_message_ts\":1000}]}")
        await MainActor.run {
            let store = AppStore(arguments: ["test"])
            defer { store.stop() }
            store.receive(rows); store.unreadOnly = true
            XCTAssertEqual(store.filteredThreads.map(\.id), ["one"])
            store.unreadOnly = false; store.searchText = "du an"
            XCTAssertEqual(store.filteredThreads.map(\.id), ["two"])
            store.selectThread("missing")
            XCTAssertNil(store.selectedThreadID)
        }
    }

    func testLateCallFromPreviousAccountCannotAppearOnNewAccount() async throws {
        let incoming = try event("{\"event\":\"incoming_call\",\"data\":{\"account\":\"old-user\",\"caller_name\":\"Private caller\"}}")
        await MainActor.run {
            let store = AppStore(arguments:["test","--demo"])
            store.session = SessionSnapshot(loggedIn:true,uin:"new-user",name:"Test")
            store.handleBAEvent(incoming)
            XCTAssertNil(store.features.incomingCall)
        }
    }

    func testComposerAssistTokensOnlyMatchTheirOwnDraftShapes() {
        XCTAssertEqual(ComposerAssistText.quickReplyQuery("/Chao"), "chao")
        XCTAssertNil(ComposerAssistText.quickReplyQuery("/chao ban"))
        XCTAssertEqual(ComposerAssistText.mentionQuery("Nhờ @Lan"), "Lan")
        XCTAssertNil(ComposerAssistText.mentionQuery("gửi tới a@b "))
        XCTAssertEqual(ComposerAssistText.insertingMention("Lan Anh", into: "Nhờ @La"), "Nhờ @Lan Anh ")
        XCTAssertEqual(ComposerAssistText.stickerKeyword(" chào "), "chào")
        XCTAssertNil(ComposerAssistText.stickerKeyword("chào bạn"))
        XCTAssertNil(ComposerAssistText.stickerKeyword("/chao"))
        XCTAssertEqual(ComposerAssistText.sectionLetter("Đặng Minh"), "D")
        XCTAssertEqual(ComposerAssistText.sectionLetter("Ánh"), "A")
        XCTAssertEqual(ComposerAssistText.sectionLetter("123"), "#")
    }

    func testJumpScrollsToLoadedMessageAndReportsOneOutsideLoadedHistory() async throws {
        let rows = try event("{\"event\":\"threads\",\"data\":[{\"id\":\"one\",\"name\":\"An Phát\",\"last_message_ts\":1000}]}")
        let snapshot = try event("{\"event\":\"messages\",\"data\":{\"thread_id\":\"one\",\"messages\":[{\"id\":\"msg-1\",\"text\":\"Xin chào\",\"timestamp\":1}]}}")
        var finished = try event("{\"event\":\"result\",\"command\":\"load_messages\",\"ok\":true,\"data\":{}}")
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.ready = true; store.receive(rows); store.selectThread("one"); store.receive(snapshot)
            store.jump(toThread: "one", messageID: "msg-1")
            XCTAssertEqual(store.jumpMessageID, "msg-1")
            XCTAssertNil(store.pendingJump)
            store.jumpMessageID = nil
            store.jump(toThread: "one", messageID: "older")
            XCTAssertNil(store.jumpMessageID)
            XCTAssertEqual(store.historyLimits["one"], 2_000)
            // An unrelated snapshot must not end the search before its own request returns.
            store.receive(snapshot)
            XCTAssertNotNil(store.pendingJump)
            XCTAssertNil(store.error)
            finished.id = store.pendingJump?.request; store.receive(finished)
            XCTAssertNil(store.pendingJump)
            XCTAssertNotNil(store.error)
            store.jump(toThread: "missing", messageID: "msg-1")
            XCTAssertEqual(store.selectedThreadID, "one")
        }
    }

    func testFailedAttachmentReturnsToComposerAndSelectionForwardsEveryMessage() async throws {
        let rows = try event("{\"event\":\"threads\",\"data\":[{\"id\":\"one\",\"name\":\"An Phát\",\"last_message_ts\":1000},{\"id\":\"two\",\"name\":\"Nhóm thử\",\"is_group\":true,\"last_message_ts\":900}]}")
        let snapshot = try event("{\"event\":\"messages\",\"data\":{\"thread_id\":\"one\",\"messages\":[{\"id\":\"a\",\"text\":\"Một\",\"timestamp\":1},{\"id\":\"b\",\"text\":\"Hai\",\"timestamp\":2}]}}")
        var failed = try event("{\"event\":\"result\",\"command\":\"send_attachment\",\"ok\":false,\"error\":\"Chưa gửi được tệp.\"}")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ctdo-test-\(UUID().uuidString).txt")
        try Data("thử".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"])
            defer { store.stop() }
            store.session = SessionSnapshot(loggedIn: true, uin: "user-1", name: "Người dùng thử")
            store.ready = true; store.capabilities = ["send_attachment", "forward_message"]
            store.receive(rows); store.selectThread("one"); store.receive(snapshot)
            store.addAttachments([file, file, FileManager.default.temporaryDirectory])
            XCTAssertEqual(store.pendingAttachments, [file])
            store.submitComposer()
            XCTAssertTrue(store.pendingAttachments.isEmpty)
            XCTAssertTrue(store.busy.contains("send_attachment"))
            failed.id = store.attachmentRequests.keys.first; store.receive(failed)
            XCTAssertEqual(store.pendingAttachments, [file])
            XCTAssertNotNil(store.error)
            store.selectingMessages = true; store.selectedMessageIDs = ["a", "b"]
            store.forwardChosen()
            XCTAssertEqual(store.forwardQueue.map(\.id), ["a", "b"])
            XCTAssertTrue(store.showingForward)
            store.selectThread("two")
            XCTAssertTrue(store.pendingAttachments.isEmpty)
        }
    }

    @MainActor
    func testImageWithUrlTextPastesAsPendingAttachmentWithoutSending() async throws {
        let store=AppStore(arguments:["test","--demo"])
        defer {store.discardTemporaryUploads();store.stop()}
        store.threads=[try JSONDecoder().decode(ThreadSnapshot.self,from:Data("{\"id\":\"thread-1\",\"name\":\"Example\"}".utf8))]
        store.selectedThreadID="thread-1";store.capabilities=["send_attachment"]
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
        bitmap.bitmapData?.initialize(repeating:255,count:16)
        let board=NSPasteboard(name:NSPasteboard.Name("ctdo-image-test-"+UUID().uuidString))
        defer {board.clearContents()}
        board.clearContents();board.setString("https://example.invalid/photo",forType:.string)
        board.setData(bitmap.representation(using:.png,properties:[:]),forType:.png)
        XCTAssertTrue(store.pasteAttachments(from:board))
        for _ in 0..<50 {if !store.pendingAttachments.isEmpty {break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(store.pendingAttachments.count,1)
        if let attachment=store.pendingAttachments.first {XCTAssertTrue(attachment.isFileURL)}
        XCTAssertFalse(store.busy.contains("send_attachment"))
    }

 @MainActor func testTypingDoesNotInvalidateTranscriptRows() throws {
  let store=AppStore(arguments:["test","--demo"])
  let thread=try JSONDecoder().decode(ThreadSnapshot.self,from:Data("{\"id\":\"thread-1\",\"name\":\"Example\"}".utf8))
  store.threads=[thread];store.selectThread(thread.id)
  let snapshot=try event("{\"event\":\"messages\",\"data\":{\"thread_id\":\"thread-1\",\"messages\":[{\"id\":\"one\",\"text\":\"Original\"}]}}")
  store.receive(snapshot)
  var updates=0
  let subscription=store.transcript.objectWillChange.sink{updates+=1}
  for i in 0..<100 {store.draft="Typing \(i)"}
  XCTAssertEqual(updates,0);XCTAssertEqual(store.transcript.rows.count,1)
  subscription.cancel();store.stop()
 }


    func testTypingDoesNotRedrawTheWholeWindowPerKeystroke() async throws {
        try await MainActor.run {
            let store = AppStore(arguments: ["test", "--demo"]); defer { store.stop() }
            var storeChanges = 0, composerChanges = 0
            let a = store.objectWillChange.sink { _ in storeChanges += 1 }
            let b = store.composer.objectWillChange.sink { _ in composerChanges += 1 }
            for text in ["x", "xi", "xin", "xin ", "xin c"] { store.draft = text }
            XCTAssertEqual(composerChanges, 5)
            XCTAssertEqual(storeChanges, 0, "each keystroke must not invalidate every view observing the store")
            XCTAssertEqual(store.draft, "xin c")
            _ = (a, b)
        }
        // The conversation list catches up once typing pauses.
        try await Task.sleep(nanoseconds: 900_000_000)
    }
}
