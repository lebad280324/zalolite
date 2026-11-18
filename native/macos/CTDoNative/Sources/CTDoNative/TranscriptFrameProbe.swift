import AppKit
import SwiftUI
import QuartzCore
import NativeBridge

#if LEGACY_MACOS13
/// The frame probe needs `CADisplayLink`, which is macOS 14 only; the macOS 13 edition skips it.
@MainActor
func runTranscriptFrameProbeIfRequested(_ store: AppStore) async {}
#else

/// Development-only frame probe. It drives the real window with synthetic history and reports
/// missed display refreshes, reading-position jumps and rows whose height is wrong on screen.
/// Runs only with `--demo` and `CTDOZLITE_FRAME_PROBE=<report.json>`; never touches a signed-in account.
@MainActor
func runTranscriptFrameProbeIfRequested(_ store: AppStore) async {
    // A file path in the arguments makes AppKit treat the launch as "open document" and suppresses the main window.
    guard store.demo, let path = ProcessInfo.processInfo.environment["CTDOZLITE_FRAME_PROBE"], !path.isEmpty else { return }
    let probe = TranscriptFrameProbe(store: store)
    let report = await probe.run()
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    exit(0)
}

@MainActor
private final class TranscriptFrameProbe: NSObject {
    private let store: AppStore
    private var link: CADisplayLink?
    private var frame: CFTimeInterval = 1.0 / 120
    private var stamps: [CFTimeInterval] = []
    private var turns: [(start: CFTimeInterval, length: Double)] = []
    private var turnStart: CFTimeInterval?
    private var observers: [CFRunLoopObserver] = []
    private var onTick: ((CFTimeInterval) -> Void)?
    private var fixtures: [String: [MessageSnapshot]] = [:]
    private var paging: Set<String> = []
    private var tracked: (id: String, y: CGFloat)?
    private var jumps: [CGFloat] = []

    init(store: AppStore) { self.store = store }

    // MARK: Fixture

    private func installFixture() {
        let names = ["Hồng Hương", "Nghiêm Lai", "Hải", "Thu Hương", "Quyền", "Huỳnh Thùy"]
        let sentences = ["Chốt thứ 6 chứ cả nhà", "e thấy vào tối t6 có được k ạ ace", "Tối thứ 6 tớ okie nhé!",
            "Anh chị ơi, quy trình này đã được ban hành chưa, em chưa thấy thông báo chính thức ở đâu cả.",
            "Trong đó đang có một phần nhỏ về quy định phân quyền duyệt đơn hàng đang mới so với bản phân quyền cũ từ năm trước.",
            "ok", "Dạ vâng ạ", "Mai họp lúc 9 giờ nhé mọi người, phòng họp tầng 5.", "😂😂😂", "uh thế mai"]
        let colors: [NSColor] = [.systemTeal, .systemIndigo, .systemPink, .systemOrange, .systemGreen, .systemBlue, .systemPurple, .systemBrown]
        for n in 0..<16 {
            let size = NSSize(width: 360, height: n % 3 == 0 ? 480 : 270)
            let image = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [colors[n % 8], colors[(n + 3) % 8]])?.draw(in: rect, angle: CGFloat(n * 23)); return true
            }
            // Rasterise once so drawing cost matches a decoded bitmap.
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
                seedPhotoCacheForDiagnostics(URL(string: "https://probe.invalid/photo-\(n).jpg")!, NSImage(cgImage: cg, size: size))
            }
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        var threads: [[String: Any]] = []
        for (t, key) in ["a", "b", "c"].enumerated() {
            let id = "probe-\(key)"
            var stamp = 1_790_000_000_000.0
            var rows: [[String: Any]] = []
            for i in 0..<1000 {
                stamp += Double(next(8) == 0 ? 2_400_000 + next(40_000_000) : 15_000 + next(240_000))
                let sender = next(names.count)
                var row: [String: Any] = ["id": "\(id)-\(i)", "timestamp": stamp, "sender_id": "user-\(sender)",
                    "sender_name": names[sender], "is_outgoing": next(4) == 0]
                let kind = next(100)
                switch kind {
                case 0..<52: row["text"] = sentences[next(sentences.count)]
                case 52..<72: row["text"] = (0..<(2 + next(4))).map { _ in sentences[3 + next(2)] }.joined(separator: " ")
                case 72..<80:
                    row["text"] = (0..<(3 + next(5))).map { _ in (0..<(2 + next(5))).map { _ in sentences[3 + next(2)] }.joined(separator: " ") }.joined(separator: "\n\n")
                case 80..<88: row["text"] = "[Hình ảnh]"; row["image_url"] = "https://probe.invalid/photo-\(next(16)).jpg"
                case 88..<91: row["text"] = sentences[4]; row["image_url"] = "https://probe.invalid/photo-\(next(16)).jpg"
                case 91..<96:
                    row["text"] = sentences[next(sentences.count)]
                    row["reply_to_id"] = "\(id)-\(max(0, i - 1 - next(6)))"; row["reply_to_sender"] = names[next(names.count)]; row["reply_to_text"] = sentences[next(sentences.count)]
                case 96..<98: row["text"] = "https://example.invalid/bai-viet"; row["link_url"] = "https://example.invalid/bai-viet"; row["link_title"] = "Thông báo lịch họp quý và các đầu việc cần chuẩn bị"
                default: row["text"] = "Bao_cao_tong_ket.docx"; row["msg_type"] = "chat.link"; row["link_url"] = "https://example.invalid/Bao_cao_tong_ket.docx"; row["link_title"] = "Bao_cao_tong_ket.docx"
                }
                if next(14) == 0 { row["reactions"] = ["❤️"] }
                rows.append(row)
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows), let decoded = try? JSONDecoder().decode([MessageSnapshot].self, from: data) { fixtures[id] = decoded }
            threads.append(["id": id, "name": "Probe \(key.uppercased())", "is_group": t != 2, "last_message": "probe", "last_message_ts": stamp])
        }
        if let data = try? JSONSerialization.data(withJSONObject: threads), let decoded = try? JSONDecoder().decode([ThreadSnapshot].self, from: data) {
            store.threads = (store.threads.filter { !$0.id.hasPrefix("probe-") } + decoded).sorted { $0.id < $1.id }
        }
        store.diagnosticsPager = { [weak self] thread, more, newer in self?.page(thread, more: more, newer: newer) }
        // Probe threads are unknown to the worker; never ask it about them.
        for id in fixtures.keys { store.features.members[id] = [] }
    }

    /// Serves pages of fifty after a short delay, like the local history store.
    private func page(_ thread: ThreadSnapshot, more: Bool, newer: Bool) {
        guard let full = fixtures[thread.id], !paging.contains(thread.id) else { return }
        let current = store.messages[thread.id] ?? []
        if !more && !newer && !current.isEmpty { return }
        if more && store.historyHasMore[thread.id] == false { return }
        if newer && store.historyHasNewer[thread.id] != true { return }
        paging.insert(thread.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self else { return }
            self.paging.remove(thread.id)
            let current = self.store.messages[thread.id] ?? []
            if current.isEmpty {
                self.store.historyHasMore[thread.id] = true
                self.store.diagnosticsIngest(Array(full.suffix(50)), threadID: thread.id, older: false)
            } else if more, let first = current.first, let at = full.firstIndex(where: { $0.id == first.id }), at > 0 {
                let start = max(0, at - 50)
                self.store.historyHasMore[thread.id] = start > 0
                self.store.diagnosticsIngest(Array(full[start..<at]) + current, threadID: thread.id, older: true)
            } else if newer, let last = current.last, let at = full.firstIndex(where: { $0.id == last.id }), at < full.count - 1 {
                let end = min(full.count, at + 51)
                self.store.historyHasNewer[thread.id] = end < full.count
                self.store.diagnosticsIngest(current + Array(full[(at + 1)..<end]), threadID: thread.id, older: false)
            }
        }
    }

    // MARK: Timing

    private func startTiming(in view: NSView) {
        let display = view.displayLink(target: self, selector: #selector(tick(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        display.add(to: .main, forMode: .common)
        link = display
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnStart = CACurrentMediaTime() }
        }
        // Ordered after Core Animation's commit observer, so a turn includes layout, display and commit.
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.turnStart else { return }
                self.turns.append((start, (CACurrentMediaTime() - start) * 1000)); self.turnStart = nil
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes); observers.append(observer) }
    }

    @objc private func tick(_ display: CADisplayLink) {
        let duration = display.targetTimestamp - display.timestamp
        if duration > 0 { frame = duration }
        stamps.append(display.timestamp)
        onTick?(duration > 0 ? duration : frame)
    }

    private func summary(from: CFTimeInterval, to: CFTimeInterval) -> [String: Any] {
        let window = stamps.filter { $0 >= from && $0 <= to }
        var missed = 0, longest = 0.0
        for (a, b) in zip(window, window.dropFirst()) {
            let gap = b - a
            longest = max(longest, gap * 1000)
            missed += max(0, Int((gap / frame).rounded()) - 1)
        }
        let work = turns.filter { $0.start >= from && $0.start <= to }.map(\.length).sorted()
        func percentile(_ p: Double) -> Double { work.isEmpty ? 0 : work[min(work.count - 1, Int(Double(work.count) * p))] }
        func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return ["frames": window.count, "missed_frames": missed, "longest_frame_gap_ms": round2(longest),
                "frame_ms": round2(frame * 1000), "turn_p50_ms": round2(percentile(0.5)), "turn_p95_ms": round2(percentile(0.95)),
                "turn_p99_ms": round2(percentile(0.99)), "turn_max_ms": round2(work.last ?? 0),
                "turns_over_frame": work.filter { $0 > self.frame * 1000 }.count]
    }

    private func log(_ text: String) { FileHandle.standardError.write(Data("[frame-probe] \(text)\n".utf8)) }
    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // MARK: Views

    private var window: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "main" } ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }
    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
    private weak var knownScroll: TranscriptScrollView?
    private var scroll: TranscriptScrollView? {
        if let knownScroll, knownScroll.window != nil { return knownScroll }
        knownScroll = find(TranscriptScrollView.self, in: window?.contentView?.superview ?? window?.contentView)
        return knownScroll
    }
    private var table: NSTableView? { scroll?.documentView as? NSTableView }
    private var coordinator: NativeTranscript.Coordinator? { table?.delegate as? NativeTranscript.Coordinator }

    /// A row in the middle of the viewport must only move by the amount the probe scrolled.
    private func noteJump() {
        guard let table, let scroll, let coordinator else { tracked = nil; return }
        if let tracked, let row = coordinator.displayed.firstIndex(where: { $0.id == tracked.id }), row < table.numberOfRows {
            let moved = table.rect(ofRow: row).minY - scroll.contentView.bounds.minY - tracked.y
            if abs(moved) > 0.5 { jumps.append(abs(moved)) }
        }
    }
    private func track() {
        guard let table, let scroll, let coordinator else { tracked = nil; return }
        let clip = scroll.contentView.bounds
        let row = table.row(at: NSPoint(x: 10, y: clip.midY))
        guard row >= 0, coordinator.displayed.indices.contains(row) else { tracked = nil; return }
        tracked = (coordinator.displayed[row].id, table.rect(ofRow: row).minY - clip.minY)
    }

    private func settle() async -> [String: Any] {
        let mismatches = coordinator?.diagnosticsVisibleMismatches() ?? (store.selectedThreadID == nil ? [] : ["no transcript"])
        var result: [String: Any] = ["wrong_rows_on_stop": mismatches.count, "jumps": jumps.count, "largest_jump_pt": Double(jumps.max() ?? 0),
            "configured": TranscriptDiagnostics.configured, "measured": TranscriptDiagnostics.measured, "rows": coordinator?.displayed.count ?? 0,
            "draws": TranscriptDiagnostics.drawn, "redraws_from_apply": TranscriptDiagnostics.applyRedraws, "redraws_from_appearance": TranscriptDiagnostics.appearanceRedraws, "draw_total_ms": (Double(TranscriptDiagnostics.drawNanos) / 10_000).rounded() / 100,
            "layouts": TranscriptDiagnostics.layouts, "layout_total_ms": (Double(TranscriptDiagnostics.layoutNanos) / 10_000).rounded() / 100,
            "update_max_ms": (Double(TranscriptDiagnostics.updateMaxNanos) / 10_000).rounded() / 100,
            "page_update_max_ms": (Double(TranscriptDiagnostics.contentUpdateMaxNanos) / 10_000).rounded() / 100]
        if !mismatches.isEmpty { result["wrong_rows_sample"] = Array(mismatches.prefix(4)) }
        jumps.removeAll(); tracked = nil
        TranscriptDiagnostics.reset()
        await wait(0.9)
        result["wrong_rows_after_idle"] = coordinator?.diagnosticsVisibleMismatches().count ?? (store.selectedThreadID == nil ? 0 : -1)
        result["window_visible"] = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        return result
    }

    /// Optional stills for visual review, written to `CTDOZLITE_FRAME_PROBE_SHOTS`.
    private func shot(_ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["CTDOZLITE_FRAME_PROBE_SHOTS"], !directory.isEmpty,
              let content = window?.contentView else { return }
        await wait(0.35)
        let view = content.superview ?? content
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"), options: .atomic)
        }
    }

    // MARK: Scenarios

    private func scrollSegment(_ name: String, seconds: Double, velocity: CGFloat) async -> [String: Any] {
        TranscriptDiagnostics.reset()
        if let scroll { NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll) }
        let start = CACurrentMediaTime()
        onTick = { [weak self] duration in
            guard let self, let scroll = self.scroll, let table = self.table else { return }
            self.noteJump()
            let clip = scroll.contentView
            let low = -scroll.contentInsets.top, high = max(low, table.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
            clip.scroll(to: NSPoint(x: 0, y: max(low, min(high, clip.bounds.minY + velocity * CGFloat(duration)))))
            scroll.reflectScrolledClipView(clip)
            self.track()
        }
        await wait(seconds)
        onTick = nil
        let end = CACurrentMediaTime()
        if let scroll { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) }
        var result = summary(from: start, to: end)
        result["scenario"] = name
        for (key, value) in await settle() { result[key] = value }
        log("\(name): \(result["frames"] ?? 0) frames, \(result["missed_frames"] ?? 0) missed")
        return result
    }

    private func resizeSegment(_ name: String, speed: CGFloat, low: CGFloat, high: CGFloat, passes: Int) async -> [String: Any] {
        guard let window else { return ["scenario": name, "error": "no window"] }
        TranscriptDiagnostics.reset()
        let before = coordinator?.anchor()
        var direction: CGFloat = -1, remaining = passes * 2
        let start = CACurrentMediaTime()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            // An occluded window stops receiving refresh callbacks; never wait for them forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard !finished else { return }
                finished = true; self?.onTick = nil; self?.log("resize timed out"); done.resume()
            }
            onTick = { [weak self] duration in
                guard let self, !finished else { return }
                var frame = window.frame
                let top = frame.maxY
                frame.size.width = max(low, min(high, frame.width + direction * speed * CGFloat(duration)))
                frame.origin.y = top - frame.height
                window.setFrame(frame, display: true)
                if frame.width <= low || frame.width >= high {
                    direction = -direction; remaining -= 1
                    if remaining == 0 { finished = true; self.onTick = nil; done.resume() }
                }
            }
        }
        let end = CACurrentMediaTime()
        var result = summary(from: start, to: end)
        result["scenario"] = name
        await wait(0.05)
        let after = coordinator?.anchor()
        result["anchor_kept"] = before?.messageID == after?.messageID && before?.bottom == after?.bottom
        result["anchor_offset_drift_pt"] = Double(abs((before?.offset ?? 0) - (after?.offset ?? 0)))
        for (key, value) in await settle() { result[key] = value }
        log("\(name): \(result["frames"] ?? 0) frames, \(result["missed_frames"] ?? 0) missed")
        return result
    }

    private func switchSegment(_ name: String, order: [String]) async -> [String: Any] {
        TranscriptDiagnostics.reset()
        var content: [Double] = [], blocked: [Double] = [], missed = 0, wrong = 0
        for id in order {
            let start = CACurrentMediaTime()
            var shown: CFTimeInterval?
            onTick = { [weak self] _ in
                guard shown == nil, let self, let table = self.table, let scroll = self.scroll, self.coordinator?.parent.threadID == id else { return }
                let visible = table.rows(in: scroll.contentView.bounds)
                if visible.length > 0, table.view(atColumn: 0, row: visible.location, makeIfNecessary: false) != nil { shown = CACurrentMediaTime() }
            }
            store.selectThread(id)
            await wait(0.45)
            onTick = nil
            let end = CACurrentMediaTime()
            content.append(((shown ?? end) - start) * 1000)
            let part = summary(from: start, to: end)
            blocked.append(part["turn_max_ms"] as? Double ?? 0)
            missed += part["missed_frames"] as? Int ?? 0
            wrong += coordinator?.diagnosticsVisibleMismatches().count ?? 1
        }
        func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        log("\(name): \(missed) missed, longest block \(blocked.max() ?? 0) ms")
        return ["scenario": name, "switches": order.count, "missed_frames": missed, "wrong_rows": wrong,
                "click_to_content_avg_ms": round2(content.reduce(0, +) / Double(max(1, content.count))), "click_to_content_max_ms": round2(content.max() ?? 0),
                "longest_block_avg_ms": round2(blocked.reduce(0, +) / Double(max(1, blocked.count))), "longest_block_max_ms": round2(blocked.max() ?? 0),
                "configured": TranscriptDiagnostics.configured, "measured": TranscriptDiagnostics.measured,
                "update_max_ms": (Double(TranscriptDiagnostics.updateMaxNanos) / 10_000).rounded() / 100, "draws": TranscriptDiagnostics.drawn,
                "draw_total_ms": (Double(TranscriptDiagnostics.drawNanos) / 10_000).rounded() / 100]
    }

    func run() async -> [String: Any] {
        for _ in 0..<50 { if store.ready && window?.contentView != nil { break }; await wait(0.2) }
        await wait(0.8)
        guard let window, let content = window.contentView else { return ["error": "no window"] }
        installFixture()
        TranscriptDiagnostics.enabled = true
        // Refresh callbacks pause for a covered window, so the probe stays above other windows while it runs.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        log("ready=\(store.ready) loggedIn=\(store.session.loggedIn) threads=\(store.threads.count)")
        if let visible = window.screen?.visibleFrame {
            window.setFrame(NSRect(x: visible.minX + 40, y: visible.maxY - 800, width: 1180, height: 760), display: true)
        }
        startTiming(in: content)
        await wait(0.5)
        log("refresh callbacks in 0.5 s: \(stamps.count), transcript=\(scroll != nil)")
        guard stamps.count > 20 else { return ["error": "window receives no refresh callbacks (covered or display asleep)"] }
        var scenarios: [[String: Any]] = []
        let a = "probe-a", b = "probe-b", c = "probe-c"
        // Optional comma-separated subset: switch, scroll, resize.
        let only = Set((ProcessInfo.processInfo.environment["CTDOZLITE_FRAME_PROBE_ONLY"] ?? "switch,scroll,shell,resize").split(separator: ",").map(String.init))
        if only.contains("switch") {
            scenarios.append(await switchSegment("switch_first_open", order: [a, b, c]))
            scenarios.append(await switchSegment("switch_recent_50_rows", order: [a, b, c, a, b, c, a, b, c]))
        }
        store.selectThread(a); await wait(0.6)
        await shot("a-latest")
        if only.contains("scroll") {
            scenarios.append(await scrollSegment("scroll_older_1500pt_s", seconds: 3, velocity: -1500))
            scenarios.append(await scrollSegment("scroll_older_6000pt_s", seconds: 3, velocity: -6000))
            scenarios.append(await scrollSegment("scroll_older_15000pt_s", seconds: 2.5, velocity: -15000))
            scenarios.append(await scrollSegment("scroll_newer_6000pt_s", seconds: 3, velocity: 6000))
            scenarios.append(await scrollSegment("scroll_newer_15000pt_s", seconds: 2.5, velocity: 15000))
            scenarios.append(await scrollSegment("scroll_older_again_6000pt_s", seconds: 3, velocity: -6000))
        } else { _ = await scrollSegment("prepare_history", seconds: 3, velocity: -6000) }
        await shot("a-history")
        if only.contains("shell") {
            // The window without a conversation: what the surrounding interface costs on its own.
            store.selectThread(nil); await wait(0.6)
            scenarios.append(await resizeSegment("resize_without_conversation_1200pt_s", speed: 1200, low: 780, high: 1180, passes: 2))
            store.selectThread(a); await wait(0.6)
        }
        if only.contains("resize") {
            scenarios.append(await resizeSegment("resize_mid_history_1200pt_s", speed: 1200, low: 780, high: 1180, passes: 2))
            scenarios.append(await resizeSegment("resize_mid_history_3000pt_s", speed: 3000, low: 780, high: 1180, passes: 3))
            var narrow = window.frame; narrow.size.width = 780
            window.setFrame(narrow, display: true)
            await shot("a-history-narrow")
            narrow.size.width = 1180; window.setFrame(narrow, display: true)
            store.selectThread(b); await wait(0.6)
            await shot("b-latest")
            scenarios.append(await resizeSegment("resize_at_bottom_1200pt_s", speed: 1200, low: 780, high: 1180, passes: 2))
        }
        if only.contains("scroll") {
            store.selectThread(b); await wait(0.6)
            scenarios.append(await scrollSegment("scroll_b_older_6000pt_s", seconds: 3, velocity: -6000))
        }
        if only.contains("switch") {
            scenarios.append(await switchSegment("switch_loaded_history", order: [a, b, c, a, b, a, b, c, a, b]))
        }
        var pointerInside = false
        if let scroll { pointerInside = scroll.bounds.contains(scroll.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        return ["display_hz": Double(window.screen?.maximumFramesPerSecond ?? 0), "frame_ms": frame * 1000,
                "pointer_over_transcript_at_end": pointerInside,
                "pointer_over_window_at_end": window.frame.contains(NSEvent.mouseLocation),
                "window_visible": window.isVisible && window.occlusionState.contains(.visible), "scenarios": scenarios,
                "note": "Synthetic history driven inside the real window; photos are pre-decoded and no network is involved."]
    }
}
#endif
