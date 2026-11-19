import AppKit
import SwiftUI
import NativeBridge

struct FeatureRow: Identifiable, Hashable {
    let value: JSONValue
    var id: String { string("id", "user_id", "message_id", "topic_id", "thread_id") }
    func string(_ keys: String...) -> String {
        for key in keys {
            if let text = value[key]?.string { return text }
            if let number = value[key]?.number { return String(Int64(number)) }
        }
        return ""
    }
    func flag(_ key: String) -> Bool { value[key]?.bool ?? false }
    func number(_ key: String) -> Double { value[key]?.number ?? 0 }
    static func ==(lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension JSONValue {
    var featureRows: [FeatureRow] {
        guard case .array(let rows) = self else { return [] }
        return rows.map { FeatureRow(value: $0) }
    }
}

struct BAFeatureState {
    var workspace: JSONValue?
    var contacts: [FeatureRow] = []
    var groups: [FeatureRow] = []
    var friendInvitations: [FeatureRow] = []
    var groupInvitations: [FeatureRow] = []
    var blockedContacts: [FeatureRow] = []
    var partialLists: Set<String> = []
    var copyDownloadJobs: Set<String> = []
    var members: [String: [FeatureRow]] = [:]
    var pinnedTopics: [String: [FeatureRow]] = [:]
    var usage: JSONValue?
    var syncProgress: Double = 0
    var syncMessage = "Chưa đồng bộ trong phiên này"
    var syncing = false
    var call: JSONValue?
    var incomingCall: JSONValue?
    var localFrame: NSImage?
    var remoteFrame: NSImage?
    var downloadedPath: String?
    var notification = ""
    func rows(_ key: String) -> [FeatureRow] { workspace?[key]?.featureRows ?? [] }
    func thread(_ id: String) -> FeatureRow? { rows("thread_features").first { $0.string("thread_id") == id } }
}

enum WorkspaceSection: String, CaseIterable { case messages, contacts, saved }
enum ContactSection: String, CaseIterable, Identifiable {
    case friends = "Bạn bè", groups = "Nhóm", invitations = "Lời mời kết bạn", groupInvitations = "Lời mời vào nhóm", blocked = "Danh sách chặn"
    var id: String { rawValue }
}

@MainActor
extension AppStore {
    func reloadWorkspaceFeatures() {
        if supports("get_workspace_features") { send("get_workspace_features") }
    }
    func showContacts() {
        workspaceSection = .contacts
        if supports("list_contacts") { send("list_contacts") }
        if supports("list_groups") { send("list_groups") }
    }
    func openContact(_ row: FeatureRow) {
        if let existing = threads.first(where: { $0.id == row.id }) {
            workspaceSection = .messages; selectThread(existing.id)
        } else if supports("open_contact") {
            guard !row.flag("is_group") else { error = "Hãy làm mới danh sách để mở đúng nhóm."; send("refresh_threads"); return }
            send("open_contact", parameters: ["user_id": .string(row.id), "name": .string(row.string("name")),
                                               "avatar": .string(row.string("avatar"))])
        }
    }
    func featureThread(_ command: String, thread: ThreadSnapshot, values: [String: JSONValue] = [:]) {
        guard supports(command) else { error = "Chức năng này chưa được bộ xử lý hỗ trợ."; return }
        threadCommand(command, thread: thread, parameters: values)
    }
    func setBookmark(_ message: MessageSnapshot, thread: ThreadSnapshot, marked: Bool) {
        featureThread("bookmark_message", thread: thread, values: ["message_id": .string(message.id), "bookmarked": .bool(marked)])
    }
    func isBookmarked(_ message: MessageSnapshot, thread: ThreadSnapshot) -> Bool {
        features.rows("bookmarks").contains { $0.string("thread_id") == thread.id && $0.string("message_id") == message.id }
    }
    func startCall(video: Bool) {
        guard let thread = selectedThread, supports("start_call") else { return }
        featureThread("start_call", thread: thread, values: ["is_video": .bool(video)])
    }
    func requestBackup() {
        guard supports("export_backup") else { return }
        let panel = NSSavePanel(); panel.title = "Xuất bản sao lịch sử"; panel.nameFieldStringValue = "ctdozlite-history.sqlite"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.send("export_backup", parameters: ["path": .string(url.path)]) }
        }
    }
    func downloadMedia(_ message: MessageSnapshot, copyImage: Bool = false) {
        guard supports("download_media"), let url = safeWebURL(message.imageURL ?? message.fileURL) else { return }
        // A chosen default folder skips the panel; "always ask" keeps the explicit choice.
        var isDirectory: ObjCBool = false
        if !copyImage, let saved = UserDefaults.standard.string(forKey: "nativeDownloadDirectory"), !saved.isEmpty,
           FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory), isDirectory.boolValue {
            send("download_media", parameters: ["url": .string(url.absoluteString),
                "file_name": .string(message.fileName ?? "Hinh-anh-\(message.id).png"), "directory": .string(saved)])
            return
        }
        let panel = NSOpenPanel(); panel.title = copyImage ? "Chọn thư mục tạm lưu ảnh" : "Chọn thư mục lưu tệp"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Lưu vào đây"
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                let id = self?.send("download_media", parameters: ["url": .string(url.absoluteString),
                    "file_name": .string(message.fileName ?? "Hinh-anh-\(message.id).png"), "directory": .string(directory.path)])
                if copyImage, let id { self?.copyImageRequests.insert(id) }
            }
        }
    }
    func handleBAResult(command: String, data: JSONValue?, threadID: String?, requestID: String) {
        switch command {
        case "get_workspace_features": features.workspace = data; NativeSystem.refreshReminders(self)
        case "list_contacts": features.contacts = data?["items"]?.featureRows ?? []
        case "list_groups": features.groups = data?["items"]?.featureRows ?? []
        case "list_friend_requests": features.friendInvitations = data?["items"]?.featureRows ?? []
        case "list_group_invitations": features.groupInvitations = data?["items"]?.featureRows ?? []
        case "list_blocked_contacts":
            // Bare-ID rows from Zalo take the conversation's name.
            features.blockedContacts = (data?["items"]?.featureRows ?? []).map { row in
                guard row.string("name").isEmpty, let name = threads.first(where: { $0.id == row.id })?.name else { return row }
                return FeatureRow(value: .object(["id": .string(row.id), "user_id": .string(row.id), "name": .string(name)]))
            }
        case "create_group": showingCreateGroup = false; send("refresh_threads"); if supports("list_groups") { send("list_groups") }
        case "add_group_members": groupToInvite = nil; features.notification = "Đã gửi lời mời vào nhóm"
        case "accept_friend", "reject_friend": if supports("list_friend_requests") { send("list_friend_requests") }; if supports("list_contacts") { send("list_contacts") }
        case "join_group_invitation": if supports("list_group_invitations") { send("list_group_invitations") }; send("refresh_threads")
        case "set_contact_blocked":
            // The change shows at once; the server list (which may lag) is re-read after.
            if let user = data?["user_id"]?.string {
                features.blockedContacts.removeAll { $0.id == user }
                if data?["blocked"]?.bool == true {
                    let name = threads.first { $0.id == user }?.name ?? ""
                    features.blockedContacts.append(FeatureRow(value: .object(["id": .string(user), "user_id": .string(user), "name": .string(name)])))
                } else { sendBlocked.remove(user) }
            }
            if supports("list_blocked_contacts") { send("list_blocked_contacts") }
        case "get_group_members":
            if let threadID { features.members[threadID] = data?["items"]?.featureRows ?? [] }
        case "list_pinned_topics":
            if let threadID { features.pinnedTopics[threadID] = data?["items"]?.featureRows ?? [] }
        case "open_contact":
            workspaceSection = .messages
            if let id = data?["thread_id"]?.string { selectThread(id) }
        case "data_usage": features.usage = data
        case "clear_cache": features.notification = "Đã dọn bộ nhớ đệm"; send("data_usage")
        case "export_backup": features.notification = "Đã xuất bản sao lịch sử"
        case "download_media":
            if let job = data?["job_id"]?.string, copyImageRequests.remove(requestID) != nil { features.copyDownloadJobs.insert(job) }
            if let path = data?["path"]?.string {
                features.downloadedPath = path; features.notification = "Đã lưu tệp trên máy"
                if copyImageRequests.remove(requestID) != nil {
                    Task {
                        let image = await Task.detached { NSImage(contentsOfFile: path) }.value
                        if let image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
                    }
                }
            }
        case "sync_phone": features.syncing = true; features.syncMessage = "Đã bắt đầu yêu cầu đồng bộ"
        case "set_thread_priority", "set_thread_category", "bookmark_message", "pin_message_local",
             "upsert_quick_reply", "delete_quick_reply", "upsert_reminder", "delete_reminder", "hide_thread", "delete_thread":
            reloadWorkspaceFeatures()
        case "update_alias", "mark_thread_unread": send("refresh_threads")
        default: break
        }
        if data?["partial"]?.bool == true { features.partialLists.insert(command) }
    }
    func handleBAEvent(_ event: CoreEvent) {
        if let source = event.data?["account"]?.string, source != session.uin { return }
        switch event.event {
        case "call_state":
            features.call = event.data
            let state = event.data?["state"]?.string ?? ""
            if ["ended", "idle", "free", "rejected", "failed", "answered_elsewhere"].contains(state) {
                features.incomingCall = nil; features.localFrame = nil; features.remoteFrame = nil
                withdrawCallNotification()
            }
            if state == "answered_elsewhere" { connection = "Cuộc gọi đã được trả lời trên thiết bị khác" }
        case "incoming_call":
            features.incomingCall = event.data
            // Zalo rings for about a minute; never leave a stale ringing card if no end signal arrives.
            let callID = event.data?["call_id"]
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                guard let self, let current = self.features.incomingCall, current["call_id"] == callID else { return }
                self.features.incomingCall = nil
                self.withdrawCallNotification()
            }
        case "call_error": error = event.data?["message"]?.string ?? "Không thực hiện được cuộc gọi."
        case "call_frame":
            guard let encoded = event.data?["image_base64"]?.string, encoded.count < 4_000_000,
                  let bytes = Data(base64Encoded: encoded) else { return }
            let account = session.uin; let local = event.data?["is_local"]?.bool == true
            Task {
                let image = await Task.detached { NSImage(data: bytes) }.value
                guard session.uin == account else { return }
                if local { features.localFrame = image } else { features.remoteFrame = image }
            }
        case "sync_progress":
            features.syncing = true; features.syncProgress = min(1, max(0, event.data?["progress"]?.number ?? 0))
            features.syncMessage = event.data?["message"]?.string ?? "Đang đồng bộ…"
        case "sync_finished":
            features.syncing = false
            if let message = event.data?["error"]?.string, !message.isEmpty { error = message }
            else { features.syncMessage = "Đã nhập \(Int(event.data?["added"]?.number ?? 0)) tin nhắn" }
            if event.data?["cancelled"]?.bool == true { features.syncMessage = "Đã dừng đồng bộ" }
        case "download_progress": features.notification = event.data?["message"]?.string ?? "Đang tải tệp…"
        case "download_finished":
            if let failure = event.data?["error"]?.string, !failure.isEmpty { error = failure; return }
            if let path = event.data?["path"]?.string {
                features.downloadedPath = path; features.notification = "Đã lưu tệp"
                let preview = pendingPreviews[path] != nil
                completeFileDownload(path: path)
                if preview { features.downloadedPath = nil; features.notification = "" }
                if let job = event.data?["job_id"]?.string, features.copyDownloadJobs.remove(job) != nil {
                    let account = session.uin
                    Task {
                        let image = await Task.detached { NSImage(contentsOfFile: path) }.value
                        guard session.uin == account, let image else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                    }
                }
            }
        default: break
        }
    }
}

/// A member tagged from the mention suggestions; `everyone` is Zalo's ID for "@All".
struct ComposerMention: Hashable {
    static let everyone = "-1"
    let uid: String
    let name: String
}
