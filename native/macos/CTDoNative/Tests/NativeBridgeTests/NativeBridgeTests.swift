import XCTest
@testable import NativeBridge

final class NativeBridgeTests: XCTestCase {
    func testJSONLineDecoderPreservesSplitUnicodeAndMultipleEvents() throws {
        let source = Data("{\"event\":\"status\",\"data\":{\"message\":\"Đã đăng nhập\"}}\n{\"id\":\"request-1\",\"event\":\"result\",\"ok\":true,\"data\":null}\n".utf8)
        var decoder = JSONLineDecoder()
        var events: [CoreEvent] = []
        for byte in source { events += try decoder.append(Data([byte])) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data?["message"]?.string, "Đã đăng nhập")
        XCTAssertEqual(events[1].id, "request-1")
        XCTAssertEqual(events[1].ok, true)
    }

    func testJSONLineDecoderRejectsUnboundedChildOutput() throws {
        var decoder = JSONLineDecoder(maximumFrameBytes: 64)
        XCTAssertTrue(try decoder.append(Data(repeating: 0x20, count: 40)).isEmpty)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0x20, count: 25)))
        XCTAssertTrue(try decoder.append(Data("\n".utf8)).isEmpty)
    }

    func testMessageRenderingDTOAcceptsOptionalRichFieldsAndUnknownFields() throws {
        let data = Data("""
        {"id":"msg-0001","text":"Xin chào","sender_name":"Người dùng thử","timestamp":1700000000000,"is_outgoing":false,"reactions":["👍"],"reply_to_id":"msg-0000","reply_to_text":"Nội dung trước","new_server_field":42}
        """.utf8)
        let message = try JSONDecoder().decode(MessageSnapshot.self, from: data)
        XCTAssertEqual(message.id, "msg-0001")
        XCTAssertEqual(message.replyToText, "Nội dung trước")
        XCTAssertEqual(message.date.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(message.imageURL)
    }

    func testUnsafeMessageURLsCannotOpenLocalFilesOrExecuteSchemes() {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "mailto:user@example.test", "https:///", "ctdo://test", "https://user:password@example.test"] {
            XCTAssertNil(safeWebURL(value))
        }
        XCTAssertEqual(safeWebURL("https://example.test/attachment.pdf")?.host, "example.test")
    }

    func testCoreProcessExchangesJSONAndStopsWhenParentClosesInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctdo-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-core")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"ready","data":{"protocol_version":1}}'
        while IFS= read -r request; do
          printf '%s\\n' '{"event":"result","id":"request-1","command":"bootstrap","ok":true,"data":null}'
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let ready = expectation(description: "child ready")
        let result = expectation(description: "terminal response")
        let oversized = expectation(description: "oversized request rejected locally")
        let stopped = expectation(description: "child stopped")
        let core = CoreProcess(onEvent: { event in
            if event.event == "ready" { ready.fulfill() }
            if event.event == "result" && event.id == "request-large" {
                XCTAssertEqual(event.ok, false)
                oversized.fulfill()
            } else if event.event == "result" { result.fulfill() }
        }, onFailure: { error in XCTFail(error) })
        core.start(coreURL: executable, dataDirectory: directory, demo: true)
        wait(for: [ready], timeout: 4)
        core.send(id: "request-large", command: "send_message", parameters: ["text": .string(String(repeating: "a", count: 300_000))])
        wait(for: [oversized], timeout: 4)
        core.send(id: "request-1", command: "bootstrap")
        wait(for: [result], timeout: 4)
        core.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 4)
    }

    func testOverlappingStopsCompleteAfterOwnerReleasesCoreProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctdo-bridge-stop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("stubborn-core")
        let script = """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' '{"event":"ready"}'
        exec /bin/sleep 6
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let ready = expectation(description: "child ready")
        let firstStopped = expectation(description: "first stop request")
        let secondStopped = expectation(description: "second stop request")
        var core: CoreProcess? = CoreProcess(onEvent: { event in
            if event.event == "ready" { ready.fulfill() }
        }, onFailure: { error in XCTFail(error) })
        core?.start(coreURL: executable, dataDirectory: directory, demo: true)
        wait(for: [ready], timeout: 4)
        core?.stop { firstStopped.fulfill() }
        core?.stop { secondStopped.fulfill() }
        core = nil
        wait(for: [firstStopped, secondStopped], timeout: 4)
    }
}
