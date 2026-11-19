import AppKit
import SwiftUI
import UserNotifications
import NativeBridge

/// One stored message matched by a history search, addressed by stable IDs.
struct HistoryHit: Identifiable {
    let threadID: String
    let message: MessageSnapshot
    var id: String { threadID + "/" + message.id }
}

/// Pure text helpers for composer assists; kept free of UI state so they can be tested.
enum ComposerAssistText {
    /// The quick-reply shortcut being typed, when the draft is a single `/word`.
    static func quickReplyQuery(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return nil }
        return String(draft.dropFirst()).lowercased()
    }
    /// The name fragment after a trailing `@`, when the caret token is a mention.
    static func mentionQuery(_ draft: String) -> String? {
        guard let token = draft.split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace }).last,
              token.hasPrefix("@"), token.count <= 40 else { return nil }
        return String(token.dropFirst())
    }
    /// Replaces the trailing mention token with a plain-text name.
    static func insertingMention(_ name: String, into draft: String) -> String {
        guard let query = mentionQuery(draft) else { return draft }
        return String(draft.dropLast(query.count + 1)) + "@" + name + " "
    }
    /// UTF-16 ranges of the chosen `@Name` tags still present in the draft, in order of appearance.
    /// A tag the person has since edited or deleted is no longer found and is not sent.
    static func mentionRanges(_ draft: String, chosen: [ComposerMention]) -> [(uid: String, pos: Int, len: Int)] {
        let text = draft as NSString
        var taken: [NSRange] = []
        var result: [(uid: String, pos: Int, len: Int)] = []
        for mention in chosen {
            let tag = "@" + mention.name
            var search = NSRange(location: 0, length: text.length)
            while search.length > 0 {
                let found = text.range(of: tag, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if !taken.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    taken.append(found); result.append((mention.uid, found.location, found.length)); break
                }
                search = NSRange(location: found.upperBound, length: text.length - found.upperBound)
            }
        }
        return result.sorted { $0.pos < $1.pos }
    }
    /// A single short word is the only draft shape that asks for sticker suggestions.
    static func stickerKeyword(_ draft: String) -> String? {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(word.count), !word.contains(where: { $0.isWhitespace }),
              !word.hasPrefix("/"), !word.hasPrefix("@") else { return nil }
        return word
    }
    /// Section letter for an alphabetical contact list, ignoring Vietnamese diacritics.
    static func sectionLetter(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi"))
            .replacingOccurrences(of: "đ", with: "d")
        guard let first = folded.trimmingCharacters(in: .whitespaces).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

@MainActor
extension AppStore {
    // MARK: Jump to a message

    func jump(toThread threadID: String, messageID: String) {
        guard !messageID.isEmpty, threads.contains(where: { $0.id == threadID }) else {
            error = "Hội thoại không còn trong danh sách. Hãy làm mới rồi thử lại."; return
        }
        workspaceSection = .messages
        showingInspector = false
        if selectedThreadID != threadID { selectThread(threadID) }
        pendingJump = (threadID, messageID, nil)
        resolveJump()
    }

    /// Scrolls once the target is loaded; otherwise asks for the widest window exactly once.
    func resolveJump(finishedRequest: String? = nil) {
        guard let jump = pendingJump else { return }
        guard jump.threadID == selectedThreadID, let thread = selectedThread else { pendingJump = nil; return }
        if let target = resolveMessageID(jump.messageID, in: messages[thread.id] ?? []) {
            pendingJump = nil; conversationSearch = ""; jumpMessageID = target; return
        }
        if jump.request == nil {
            historyLimits[thread.id] = 2_000
            let request = send("load_messages", parameters: ["thread_id": .string(thread.id), "is_group": .bool(thread.isGroup),
                                                              "limit": .number(2_000)], threadID: thread.id)
            if let request { pendingJump = (jump.threadID, jump.messageID, request) } else { pendingJump = nil }
        } else if finishedRequest == jump.request {
            pendingJump = nil
            error = "Tin gốc nằm ngoài phần lịch sử đã tải trên máy. Hãy đồng bộ lịch sử rồi thử lại."
        }
    }

    /// The message a quote points at. Quotes carry the sender's client ID (the send time in
    /// milliseconds), while history is keyed by the server ID, so an exact match often fails.
    /// Fall back to the quoted text and sender, then to the closest send time from that sender.
    func resolveMessageID(_ id: String, in list: [MessageSnapshot]) -> String? {
        if list.contains(where: { $0.id == id }) { return id }
        guard let reply = list.last(where: { $0.replyToID == id }) else { return nil }
        let text = (reply.replyToText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = reply.replyToSender ?? ""
        let sentAt = Double(id).map { $0 > 100_000_000_000 ? $0 : $0 * 1_000 }
        let earlier = list.filter { $0.id != reply.id && $0.timestamp <= reply.timestamp }
        func sameSender(_ m: MessageSnapshot) -> Bool { sender.isEmpty || m.senderName == sender || (m.isOutgoing && sender == session.name) }
        func distance(_ m: MessageSnapshot) -> Double { sentAt.map { abs(m.timestamp - $0) } ?? (reply.timestamp - m.timestamp) }
        if !text.isEmpty {
            let byText = earlier.filter { m in
                let body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return body == text || (text.count >= 12 && body.hasPrefix(String(text.prefix(40))))
                    || (text.hasPrefix("[") && (m.imageURL != nil || m.fileURL != nil) && sameSender(m))
            }
            if let best = byText.filter(sameSender).min(by: { distance($0) < distance($1) }) ?? byText.min(by: { distance($0) < distance($1) }) {
                return best.id
            }
        }
        if let sentAt, let best = earlier.filter(sameSender).min(by: { abs($0.timestamp - sentAt) < abs($1.timestamp - sentAt) }),
           abs(best.timestamp - sentAt) < 10_000 { return best.id }
        return nil
    }

    // MARK: History search

    func searchHistory(_ query: String, onlyCurrentThread: Bool, filesOnly: Bool = false) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supports("search_history"), !text.isEmpty else { historySearchRequestID=nil; historyResults = []; return }
        var parameters: [String: JSONValue] = ["query": .string(text)]
        if onlyCurrentThread, let id = selectedThreadID { parameters["thread_id"] = .string(id) }
        parameters["files_only"] = .bool(filesOnly)
        historySearchRequestID = send("search_history", parameters: parameters)
    }

    // MARK: Attachments waiting in the composer

    func addAttachments(_ urls: [URL]) {
        guard selectedThread != nil, supports("send_attachment") else { return }
        var isDirectory: ObjCBool = false
        let files = urls.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        for url in files where !pendingAttachments.contains(url) { pendingAttachments.append(url) }
        if pendingAttachments.count > 10 {
            pendingAttachments = Array(pendingAttachments.prefix(10))
            error = "Mỗi lần gửi tối đa 10 tệp. Các tệp còn lại chưa được thêm."
        }
    }

    /// Reads files or an image from the clipboard. Returns false when the paste is plain text.
    func pasteAttachments(from pasteboard: NSPasteboard = .general) -> Bool {
        guard selectedThread != nil, supports("send_attachment") else { return false }
        let urls=ClipboardFiles.read(pasteboard)
        if !urls.isEmpty {addAttachments(urls);return true}
        guard let data=pasteboard.data(forType:.png) ?? pasteboard.data(forType:.tiff) ?? pasteboard.data(forType:NSPasteboard.PasteboardType("public.jpeg")) ?? pasteboard.data(forType:NSPasteboard.PasteboardType("public.heic")) else{return false}
        let threadID = selectedThreadID
        Task { @MainActor [weak self] in
            // Encoding is bounded by the clipboard image but still stays off the main actor.
            let url = await Task.detached { () -> URL? in
                guard let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("Anh-dan-\(UUID().uuidString.prefix(8)).png")
                do { try png.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); return file } catch { return nil }
            }.value
            guard let self, let url else { self?.error = "Không đọc được ảnh trong bộ nhớ tạm."; return }
            guard self.selectedThreadID == threadID else { try? FileManager.default.removeItem(at: url); return }
            self.temporaryUploads.insert(url); self.addAttachments([url])
        }
        return true
    }

    func removeAttachment(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
        if temporaryUploads.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }

    func discardTemporaryUploads() {
        for url in temporaryUploads { try? FileManager.default.removeItem(at: url) }
        temporaryUploads.removeAll()
    }

    func sendPendingAttachments() {
        guard canSend, let thread = selectedThread, supports("send_attachment"), !pendingAttachments.isEmpty,
              validDraftLength() else { return }
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, url) in pendingAttachments.enumerated() {
            let captioned = index == 0 && !caption.isEmpty
            let request = send("send_attachment", parameters: ["thread_id": .string(thread.id), "is_group": .bool(thread.isGroup),
                "path": .string(url.path), "caption": .string(captioned ? draft : "")],
                threadID: thread.id, submittedText: captioned ? draft : nil)
            if let request { attachmentRequests[request] = url }
        }
        pendingAttachments = []
    }

    /// The composer's single send action: queued files first, otherwise the text draft.
    func submitComposer() {
        if pendingAttachments.isEmpty { sendText() } else { sendPendingAttachments() }
    }

    // MARK: Composer assists

    func requestStickerSuggestions() {
        guard UserDefaults.standard.bool(forKey: "nativeStickerSuggestions"), !demo, supports("suggest_stickers"),
              let keyword = ComposerAssistText.stickerKeyword(draft) else { suggestedStickers = []; return }
        send("suggest_stickers", parameters: ["keyword": .string(keyword)])
    }

    func mentionCandidates(for thread: ThreadSnapshot) -> [FeatureRow] {
        guard thread.isGroup, UserDefaults.standard.bool(forKey: "nativeMentionSuggestions"),
              let query = ComposerAssistText.mentionQuery(draft) else { return [] }
        var rows = Array((features.members[thread.id] ?? []).filter {
            let name = $0.string("name", "display_name")
            return !name.isEmpty && $0.id != session.uin && (query.isEmpty || name.localizedStandardContains(query))
        }.prefix(6))
        // "@All" tags everyone in the group, as in Zalo.
        if query.isEmpty || "all".localizedStandardContains(query) || "tất cả".localizedStandardContains(query) {
            rows.insert(FeatureRow(value: .object(["id": .string(ComposerMention.everyone), "name": .string("All")])), at: 0)
        }
        return rows
    }

    /// Replaces the typed `@…` with the chosen name and remembers who it tags, so sending notifies them.
    func insertMention(uid: String, name: String, thread: ThreadSnapshot) {
        draft = ComposerAssistText.insertingMention(name, into: draft)
        guard !uid.isEmpty else { return }
        draftMentions[thread.id, default: []].append(ComposerMention(uid: uid, name: name))
    }

    /// Member names load once per group, only after the person starts typing a mention.
    func loadMentionMembersIfNeeded(for thread: ThreadSnapshot) {
        guard thread.isGroup, UserDefaults.standard.bool(forKey: "nativeMentionSuggestions"),
              ComposerAssistText.mentionQuery(draft) != nil, features.members[thread.id] == nil,
              supports("get_group_members"), !busy.contains("get_group_members") else { return }
        threadCommand("get_group_members", thread: thread)
    }

    func quickReplyCandidates() -> [FeatureRow] {
        guard let query = ComposerAssistText.quickReplyQuery(draft) else { return [] }
        return Array(features.rows("quick_replies").filter { query.isEmpty || $0.string("shortcut").lowercased().hasPrefix(query) }.prefix(6))
    }

    func draftPreview(_ threadID: String) -> String? {
        guard threadID != selectedThreadID, let text = drafts[threadID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: Multi-select actions

    var chosenMessages: [MessageSnapshot] { selectedMessages.filter { selectedMessageIDs.contains($0.id) } }

    func finishSelecting() { selectingMessages = false; selectedMessageIDs.removeAll() }

    func forwardChosen() {
        let items = chosenMessages
        guard !items.isEmpty, supports("forward_message") else { return }
        forwardQueue = items; forwardMessage = items[0]; forwardSourceThread = selectedThread; showingForward = true
    }

    func bookmarkChosen() {
        guard let thread = selectedThread else { return }
        for message in chosenMessages where !isBookmarked(message, thread: thread) { setBookmark(message, thread: thread, marked: true) }
        finishSelecting()
    }

    func deleteChosen() {
        for message in chosenMessages { messageAction("delete_message", message: message) }
        finishSelecting()
    }

    // MARK: Contacts and groups

    func confirmBlock() {
        guard let row = blockCandidate else { return }
        blockCandidate = nil
        guard supports("set_contact_blocked") else { error = "Chức năng chặn chưa được bộ xử lý hỗ trợ."; return }
        send("set_contact_blocked", parameters: ["user_id": .string(row.id), "blocked": .bool(true)])
    }

    func contactRow(for thread: ThreadSnapshot) -> FeatureRow {
        FeatureRow(value: .object(["id": .string(thread.id), "name": .string(thread.name), "avatar": .string(thread.avatar ?? "")]))
    }

    var hiddenThreads: [ThreadSnapshot] {
        threads.filter(\.hidden).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Result and event hooks

    func handleAdditionsResult(command: String, data: JSONValue?, threadID: String?, requestID: String) {
        switch command {
        case "search_history":
            guard requestID == historySearchRequestID else { return }
            guard case .array(let rows) = data?["items"] else { historyResults = []; return }
            historyResults = rows.compactMap { row in
                guard let thread = row["thread_id"]?.string, let message = try? row["message"]?.decode(MessageSnapshot.self) else { return nil }
                guard hiddenUnlocked || !threads.contains(where:{$0.id==thread && $0.hidden}) else { return nil }
                return HistoryHit(threadID: thread, message: message)
            }
        case "send_contact":
            if let thread=threads.first(where:{$0.id==threadID}) {loadMessages(thread)}
        case "suggest_stickers":
            // A late answer must not reopen suggestions for a draft that moved on.
            guard ComposerAssistText.stickerKeyword(draft) != nil else { suggestedStickers = []; return }
            suggestedStickers = Array(((try? data?["items"]?.decode([StickerItem].self)) ?? []).prefix(8))
        case "send_sticker": suggestedStickers = []
        case "load_messages": resolveJump(finishedRequest: requestID)
        case "send_attachment":
            if let url = attachmentRequests.removeValue(forKey: requestID), temporaryUploads.remove(url) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        case "add_group_members": addToGroupUser = nil
        case "create_group": groupSeed = nil
        case "set_contact_blocked": features.notification = data?["blocked"]?.bool == false ? "Đã bỏ chặn" : "Đã cập nhật danh sách chặn"
        case "undo_friend": connection = "Đã thu hồi lời mời kết bạn"
        case "hide_thread": send("refresh_threads")
        default: break
        }
    }

    /// Returns true when the failure was absorbed and must not surface as a banner.
    func handleAdditionsFailure(command: String, requestID: String, threadID: String?) -> Bool {
        switch command {
        case "suggest_stickers": suggestedStickers = []; return true
        case "import_history": importProgress = nil; return false
        case "load_messages":
            if pendingJump?.request == requestID { pendingJump = nil }
            return false
        case "send_attachment":
            // The file returns to the composer so a failed upload can be retried or removed.
            if let url = attachmentRequests.removeValue(forKey: requestID), threadID == selectedThreadID,
               !pendingAttachments.contains(url) { pendingAttachments.append(url) }
            return false
        default: return false
        }
    }

    func handleAdditionsEvent(_ event: CoreEvent) {
        if let source = event.data?["account"]?.string, source != session.uin { return }
        switch event.event {
        case "import_progress":
            guard importProgress != nil else { return }
            importProgress = min(1, max(0, event.data?["progress"]?.number ?? 0))
            importRows = Int(event.data?["rows"]?.number ?? 0)
            importPhase = event.data?["phase"]?.string ?? "messages"
        case "download_progress": downloading = true
        case "download_finished": downloading = false
        case "incoming_call":
            guard UserDefaults.standard.bool(forKey: "nativeCallNotifications"),
                  !NSRunningApplication.current.isActive || !BackgroundMode.mainWindowVisible else { return }
            let video = event.data?["is_video"]?.bool == true
            postNotification(id: "call-\(session.uin)", title: video ? "Cuộc gọi video đến" : "Cuộc gọi thoại đến",
                             body: isLocked ? "Mở Zalolite để trả lời." : event.data?["caller_name"]?.string ?? "Mở Zalolite để trả lời.",
                             threadID: nil, category: "incoming_call")
        default: break
        }
    }

    // MARK: Notifications

    /// Unread total on the Dock icon. A chat marked unread counts as one; muted and hidden chats do not count.
    func updateDockBadge() {
        // Only a real .app bundle has a Dock tile and notification center; tests run inside xctest.
        guard Bundle.main.bundleURL.pathExtension == "app", !demo else { return }
        let enabled = UserDefaults.standard.bool(forKey: "nativeDockBadge")
        let total = enabled ? threads.filter { !$0.hidden && !$0.muted }.reduce(0) { $0 + max($1.unread, $1.markedUnread ? 1 : 0) } : 0
        NSApp?.dockTile.badgeLabel = total > 0 ? (total > 99 ? "99+" : String(total)) : nil
        NSApp?.dockTile.display()
        // Recent macOS also routes app badges through notification settings; set both paths.
        UNUserNotificationCenter.current().setBadgeCount(total) { _ in }
    }

    /// Announces conversations whose unread count grew since the previous snapshot.
    func announceIncoming(previousUnread: [String: Int], hadSnapshot: Bool) {
        let defaults = UserDefaults.standard
        updateDockBadge()
        let reading = NSRunningApplication.current.isActive && BackgroundMode.mainWindowVisible && !isLocked && workspaceSection == .messages
            && selectedThreadID.map { transcript.positions[$0]?.bottom != false } == true
        let fresh = IncomingMessagePolicy.candidates(threads, previousUnread:previousUnread, hadSnapshot:hadSnapshot,
                                                     readingThreadID:reading ? selectedThreadID : ChatHeads.shared.readingThreadID)
        if !demo { ChatHeads.shared.noteIncoming(fresh) }
        // The first snapshot of a session is history, not news.
        guard hadSnapshot, defaults.bool(forKey: "nativeNotificationsEnabled") else { return }
        for thread in fresh {
            let showPreview = defaults.bool(forKey: "nativeNotificationPreview") && !isLocked
            postNotification(id: "message-\(session.uin)-\(thread.id)", title: showPreview ? thread.name : "Zalolite",
                             body: showPreview && !thread.lastMessage.isEmpty ? thread.lastMessage : "Bạn có tin nhắn mới", threadID: thread.id)
        }
    }

    /// Removes the incoming-call banner once the call stops ringing here.
    func withdrawCallNotification() {
        guard !demo, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call-\(session.uin)"])
    }

    private func postNotification(id: String, title: String, body: String, threadID: String?, category: String? = nil) {
        // UserNotifications requires a bundled app; previews and unit tests have none.
        guard !demo, Bundle.main.bundleIdentifier != nil else { return }
        let sound = UserDefaults.standard.bool(forKey: "nativeNotificationSound")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = String(body.prefix(240))
            if sound { content.sound = .default }
            if let threadID { content.userInfo = ["thread_id": threadID] }
            if let category { content.categoryIdentifier = category; content.interruptionLevel = .timeSensitive }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
        }
    }
}

/// Startup history and manual unread marks never create incoming-message banners.
enum IncomingMessagePolicy {
    static func candidates(_ threads: [ThreadSnapshot], previousUnread: [String:Int],
                           hadSnapshot: Bool, readingThreadID: String?) -> [ThreadSnapshot] {
        guard hadSnapshot else { return [] }
        return threads.filter {
            $0.unread > (previousUnread[$0.id] ?? 0) && !$0.muted && !$0.hidden && $0.id != readingThreadID
        }
    }
}

// MARK: - Views

struct HistorySearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var currentOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tìm trong lịch sử").font(.title2.bold())
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Nội dung tin nhắn đã lưu trên máy", text: $query).textFieldStyle(.plain).onSubmit { run() }
                if store.busy.contains("search_history") { ProgressView().controlSize(.small) }
            }.padding(10).nativeGlass(12)
            if store.selectedThread != nil {
                Toggle("Chỉ tìm trong cuộc trò chuyện đang mở", isOn: $currentOnly)
            }
            List(store.historyResults) { hit in
                Button { store.jump(toThread: hit.threadID, messageID: hit.message.id); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(verbatim: store.threads.first { $0.id == hit.threadID }?.name ?? "Hội thoại đã lưu").font(.callout.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(hit.message.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: hit.message.text).font(.callout).lineLimit(3)
                        if !hit.message.senderName.isEmpty { Text(verbatim: hit.message.senderName).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(!store.threads.contains { $0.id == hit.threadID })
            }.listStyle(.inset).scrollContentBackground(.hidden)
                .overlay {
                    if store.historyResults.isEmpty && !store.busy.contains("search_history") {
                        EmptyState(query.isEmpty ? "Nhập nội dung cần tìm" : "Không có kết quả",
                                               systemImage: "text.magnifyingglass",
                                               description: Text("Chỉ tìm trong lịch sử đã lưu trên máy này, tối đa 300 kết quả."))
                    }
                }
        }
        .padding(24).frame(width: 620, height: 560)
        .onValueChange(of: currentOnly) { _, _ in run() }
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            run()
        }
        .onDisappear { store.historyResults = [] }
    }
    private func run() { store.searchHistory(query, onlyCurrentThread: currentOnly) }
}

/// Suggestions shown above the composer: quick replies, group member names and stickers.
struct ComposerAssist: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    var body: some View {
        let replies = store.quickReplyCandidates()
        let members = store.mentionCandidates(for: thread)
        VStack(alignment: .leading, spacing: 8) {
            if !replies.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(replies) { row in
                            Button { store.draft = row.string("text") } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/" + row.string("shortcut")).font(.caption.weight(.semibold))
                                    Text(verbatim: row.string("text")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: 220, alignment: .leading)
                                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).help("Chèn mẫu tin vào bản nháp")
                        }
                    }
                }
            }
            if !members.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(members) { row in
                            let name = row.string("name", "display_name")
                            Button { store.insertMention(uid: row.id, name: name, thread: thread) } label: {
                                HStack(spacing: 6) {
                                    AvatarView(name: name, url: row.string("avatar"), size: 20)
                                    Text(verbatim: name).font(.caption).lineLimit(1)
                                }.padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.primary.opacity(0.05), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if !store.suggestedStickers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.suggestedStickers) { sticker in
                            Button { store.sendSticker(sticker) } label: {
                                if let url = safeWebURL(sticker.imageURL) {
                                    AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView().controlSize(.small) }
                                        .frame(width: 46, height: 46)
                                } else { Image(systemName: "face.smiling").frame(width: 46, height: 46) }
                            }.buttonStyle(.plain).disabled(!store.canSend).help("Gửi nhãn dán gợi ý")
                        }
                        Button { store.suggestedStickers = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ẩn gợi ý nhãn dán")
                    }
                }
            }
        }
        .padding(.horizontal,18).padding(.top,replies.isEmpty && members.isEmpty && store.suggestedStickers.isEmpty ? 0 : 10)
        .task(id: store.draft) {
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            store.requestStickerSuggestions()
        }
        .onValueChange(of: store.draft) { _, _ in store.loadMentionMembersIfNeeded(for: thread) }
    }
}

/// Reply, react and forward stay one hover away; rarer actions remain in the menu.
struct AddToGroupView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let user: FeatureRow
    @State private var query = ""
    @State private var groupID: String?
    private var groups: [FeatureRow] {
        store.features.groups.filter { query.isEmpty || $0.string("name").localizedStandardContains(query) }
            .sorted { $0.string("name").localizedStandardCompare($1.string("name")) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Thêm vào nhóm").font(.title2.bold()); Spacer(); Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Chọn nhóm để mời \(user.string("name")). Nhóm có thể cần quản trị viên duyệt.").foregroundStyle(.secondary)
            TextField("Tìm nhóm", text: $query).textFieldStyle(.roundedBorder)
            List(groups, selection: $groupID) { row in
                HStack { AvatarView(name: row.string("name"), url: row.string("avatar"), size: 30, group: true); Text(verbatim: row.string("name")) }.tag(row.id)
            }.listStyle(.inset)
                .overlay { if groups.isEmpty { EmptyState("Chưa có nhóm", systemImage: "person.3", description: Text("Làm mới danh bạ để tải danh sách nhóm.")) } }
            if let error = store.error { Text(verbatim: error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Gửi lời mời") {
                    if let groupID { store.send("add_group_members", parameters: ["thread_id": .string(groupID), "member_ids": .array([.string(user.id)])]) }
                }.buttonStyle(.borderedProminent).disabled(groupID == nil || store.busy.contains("add_group_members") || !store.supports("add_group_members"))
            }
        }.padding(24).frame(width: 460, height: 500)
            .onAppear { if store.supports("list_groups") { store.send("list_groups") } }
    }
}

struct AccountInfoView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("Thông tin tài khoản").font(.title2.bold()); Spacer(); Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction) }
            AvatarView(name: store.session.name, url: store.session.avatar, size: 84)
            Text(verbatim: store.session.name.isEmpty ? "Tài khoản Zalo" : store.session.name).font(.title3.weight(.semibold)).textSelection(.enabled)
            Form {
                LabeledContent("Mã tài khoản", value: store.session.uin.isEmpty ? "Chưa có" : store.session.uin)
                LabeledContent("Trạng thái", value: store.connection)
                LabeledContent("Hội thoại đã tải", value: "\(store.threads.count)")
                LabeledContent("Thư mục dữ liệu", value: store.dataDirectory.path)
                LabeledContent("Phiên bản", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Bản phát triển")
            }.formStyle(.grouped).textSelection(.enabled)
            HStack {
                Button("Hiện dữ liệu trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory]) }
                Spacer()
                if store.supports("logout") { Button("Đăng xuất…", role: .destructive) { dismiss(); store.showingLogoutConfirmation = true } }
            }
        }.padding(24).frame(width: 500, height: 520)
    }
}

/// Transient outcome of background work: downloads, saved files and list updates.
struct StatusPill: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if !store.features.notification.isEmpty && !store.isLocked {
            HStack(spacing: 10) {
                if store.downloading { ProgressView().controlSize(.small) }
                Text(verbatim: store.features.notification).font(.callout).lineLimit(2)
                if store.downloading && store.supports("cancel_download") {
                    Button("Hủy tải") { store.send("cancel_download") }
                } else if let path = store.features.downloadedPath {
                    Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button { store.features.notification = ""; store.features.downloadedPath = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Đóng")
            }
            .padding(.horizontal, 14).padding(.vertical, 10).nativeGlass(14).shadow(color: .black.opacity(0.1), radius: 10)
            .task(id: store.features.notification) {
                // Completed notices clear themselves; an active download stays until it ends.
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                if !store.downloading { store.features.notification = ""; store.features.downloadedPath = nil }
            }
        }
    }
}
