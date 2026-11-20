import AppKit
import SwiftUI
import NativeBridge

@MainActor
final class AppStore: ObservableObject {
    let transcript=TranscriptModel()
    @Published var features = BAFeatureState() {
        didSet {
            filterCache=nil
            let id=selectedThreadID ?? ""
            if oldValue.members[id] != features.members[id] || oldValue.rows("thread_features") != features.rows("thread_features") {transcript.presentationVersion += 1}
        }
    }
    @Published var workspaceSection = WorkspaceSection.messages
    @Published var contactSection = ContactSection.friends
    @Published var selectedMessageIDs: Set<String> = []
    @Published var selectingMessages = false
    @Published var threadOptions: ThreadSnapshot?
    @Published var destructiveThread: ThreadSnapshot?
    @Published var reminderThread: ThreadSnapshot?
    @Published var selectedCategory = ""
    @Published var priorityFilter = "all"
    @Published var messageDetails: MessageSnapshot?
    @Published var showingQuickReplies = false
    @Published var isLocked = false
    @Published var privacyGuard: JSONValue?
    @Published var accountSettings: JSONValue?
    @Published var showingCreateGroup = false
    @Published var groupToInvite: ThreadSnapshot?
    @Published var mediaDevices: JSONValue?
    // Workspace additions: history search, jump-to-message, composer assists and attachments.
    @Published var jumpMessageID: String?
    @Published var highlightedMessageID: String?
    @Published var showingHistorySearch = false
    @Published var showingConversationSearch = false
    @Published var historyResults: [HistoryHit] = []
    var historySearchRequestID: String?
    @Published var suggestedStickers: [StickerItem] = []
    @Published var pendingAttachments: [URL] = []
    @Published var showingAccountInfo = false
    @Published var addToGroupUser: FeatureRow?
    @Published var groupSeed: FeatureRow?
    @Published var blockCandidate: FeatureRow?
    @Published var hiddenUnlocked = false
    @Published var requestedSettingsPage: String?
    @Published var downloading = false
    @Published var importProgress: Double?
    @Published var importRows = 0
    @Published var importSummary: String?
    /// "messages", then "media" while photos, videos and files are copied.
    @Published var importPhase = "messages"
    var forwardQueue: [MessageSnapshot] = []
    var attachmentRequests: [String: URL] = [:]
    var temporaryUploads: Set<URL> = []
    var pendingJump: (threadID: String, messageID: String, request: String?)?
    var recentlyOpenedIDs: Set<String> = []
    var copyImageRequests: Set<String> = []
    @Published var session = SessionSnapshot()
    @Published var threads: [ThreadSnapshot] = [] { didSet { filterCache = nil } }
    @Published var messages: [String: [MessageSnapshot]] = [:]
    @Published var selectedThreadID: String?
    @Published var searchText = ""
    @Published var filter = ThreadFilter.all
    var receivedThreadSnapshot = false
    @Published var unreadOnly = false
    @Published var conversationSearch = ""
    @Published var showingContactLookup = false
    @Published var contactResult: JSONValue?
    /// The text being composed lives in its own object: as a published property here, every
    /// keystroke made the whole window (conversation list, toolbar, rows) evaluate again.
    let composer = ComposerDraft()
    var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }
    private(set) var replyFocusGeneration: UInt = 0
    @Published var quote: MessageSnapshot? {
        didSet { if quote != nil { replyFocusGeneration &+= 1 } }
    }
    @Published var qrImage: NSImage?
    @Published var connection = "Đang mở ứng dụng…"
    @Published var error: String?
    @Published var ready = false
    @Published var busy: Set<String> = []
    @Published var capabilities: Set<String> = []
    @Published var dataDirectory: URL
    @Published var showingInspector = false
    @Published var showingLogoutConfirmation = false
    @Published var showingDataFolderConfirmation = false
    @Published var showingStickers = false
    @Published var showingForward = false
    @Published var showingScheduled = false
    @Published var stickerPacks: [StickerPack] = []
    @Published var stickerItems: [StickerItem] = []
    /// Sprite animation for sticker IDs, learnt from any sticker pack response.
    @Published var stickerArt: [UInt64: StickerItem] = [:]
    /// Profiles fetched with `get_profile`, by user ID.
    @Published var profiles: [String: ProfileInfo] = [:]
    /// Photos, files and links from each conversation's whole local history.
    @Published var threadLibraries: [String: ThreadLibrary] = [:]
    /// Conversations where Zalo refused delivery: blocked by, or not accepting messages from, this account.
    /// Kept per account across launches: Zalo only reveals this when a send is refused.
    /// Requests whose failure is shown where they were made, not as a banner.
    var quietRequests: Set<String> = []
    /// Original profile photos (`full_avatar`), by person ID.
    var fullAvatars: [String: String] = [:]
    /// Who is typing, from Zalo's typing controls.
    let typing = TypingTracker()
    @Published var sendBlocked: Set<String> = [] {
        didSet { if sendBlocked != oldValue, AccountFiles.isAccountID(session.uin) { BlockedBy.save(sendBlocked, account: session.uin) } }
    }
    /// Nicknames set on Zalo (`list_aliases`), by person ID; shown instead of their Zalo name, like Zalo.
    @Published var aliases: [String: String] = [:]
    /// The Zalo name behind each nickname, for the alias editor.
    var originalNames: [String: String] = [:]
    var aliasesRequested = false
    /// The person whose nickname is being edited.
    @Published var aliasThread: ThreadSnapshot?
    /// Must match `SEND_BLOCKED_MESSAGE` in the Rust worker.
    static let sendBlockedMessage = "Không gửi được tin nhắn: người này đã chặn bạn hoặc không nhận tin nhắn từ bạn."
    /// Zalo error 122, in Zalo's words: the person takes no messages from strangers.
    static let strangerBlockedMessage = "Bạn chưa thể gửi tin nhắn đến người này vì người này chặn không nhận tin nhắn từ người lạ."
    /// Conversations whose person takes no messages from strangers (Zalo error 122).
    @Published var strangerBlocked: Set<String> = []
    /// Corner radius of this window, so inner cards stay concentric with it.
    @Published var windowCornerRadius: CGFloat = 26
    /// Reopens the main window scene after it was closed; set by the first window.
    var openMainWindow: (() -> Void)?
    var profileRequests: Set<String> = []
    var stickerArtRequests: Set<String> = []
    /// File downloads started for Quick Look or saving, keyed by destination path.
    var pendingPreviews: [String: String] = [:]
    var pendingSaves: [String: String] = [:]
    @Published var fileDownloadsVersion = 0
    /// Last listing of the accounts on this Mac (see `savedAccounts`).
    var savedAccountsCache: (at: Date, accounts: [SavedAccount])?
    /// The account being switched to, shown instead of the sign-in screen while the worker restarts.
    @Published var switchingTo: SavedAccount?
    /// Unread counts the core checked for the other saved accounts, by UIN.
    @Published var liveAccountUnread: [String: AccountUnread] = [:]
    /// A message a group admin chose to delete for every member, awaiting confirmation.
    @Published var deleteForEveryoneCandidate: MessageSnapshot?
    /// Group polls loaded for notices on screen, by poll ID.
    @Published var polls: [UInt64: PollSnapshot] = [:]
    var pollRequested: [UInt64: Date] = [:]
    var stickerArtCategories: Set<UInt64> = []
    @Published var scheduledMessages: [ScheduledMessage] = []
    var forwardMessage: MessageSnapshot?
    var forwardSourceThread: ThreadSnapshot?
    var proposedDataDirectory: URL?
    let demo: Bool
    private var pending: [String: Pending] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    var drafts: [String: String] = [:]
    /// Members tagged from the suggestions in each conversation's draft.
    var draftMentions: [String: [ComposerMention]] = [:]
    var historyLimits: [String: Int] = [:]
    var historyCursors: [String: HistoryCursor] = [:]
    var historyHasMore: [String: Bool] = [:]
    var pageRequests: [String: String] = [:]
    var historyHasNewer: [String: Bool] = [:]
    private var removedMessageIDs: Set<String> = []
    private var messageCacheOrder: [String] = []
    private var lastHistoryRefresh: [String: Date] = [:]
    private var started = false
    private var generation = 0
    private var bridge: CoreProcess?

    enum ThreadFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả", personal = "Cá nhân", groups = "Nhóm"
        var id: String { rawValue }
    }
    private struct Pending {
        let command: String
        let threadID: String?
        let submittedText: String?
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        UserDefaults.standard.register(defaults: ["nativeNotificationsEnabled": true, "nativeNotificationSound": true,
            "nativeDoubleClickReply": true, "nativeShowThumbnails": true, "nativeSendWithReturn": true,
            "nativeStickerSuggestions": true, "nativeUseAvatarWallpaper": false, "nativeLockOnDeactivate": false,
            "nativeMentionSuggestions": true, "nativePrioritySplit": false, "nativeNotificationPreview": true,
            "nativeCallNotifications": true, "nativeDockBadge": true])
        demo = arguments.contains("--demo")
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ctdozlite-native", isDirectory: true)
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if demo {
            dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ctdo-native-demo-\(UUID().uuidString)", isDirectory: true)
        } else if let path = UserDefaults.standard.string(forKey: "nativeDataDirectory") {
            dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else { dataDirectory = base }
        composer.owner = self
    }

    var selectedThread: ThreadSnapshot? { threads.first { $0.id == selectedThreadID } }
    var selectedMessages: [MessageSnapshot] { messages[selectedThreadID ?? ""] ?? [] }
    /// Loaded messages of the open conversation that contain the search text, newest first.
    /// The transcript keeps every message; matches are stepped through, as in Zalo.
    var conversationSearchHits: [MessageSnapshot] {
        let query = conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return selectedMessages.filter { message in
            message.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (message.fileName ?? "").range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (message.linkTitle ?? "").range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.reversed()
    }
    /// Conversations Zalo files under "Khác" (`archived_chats` from the server), as `u:<id>` / `g:<id>`;
    /// nil until the server list has been read once.
    var archivedThreadKeys: Set<String>? {
        guard let list = features.workspace?["archived_chats"], list["synced"]?.bool == true else { return nil }
        return Set(list["items"]?.featureRows.map { ($0.flag("is_group") ? "g:" : "u:") + $0.string("id") } ?? [])
    }
    /// "Ưu tiên" unless the server lists the conversation under "Khác"; before the first sync the local flag decides.
    func isPriority(_ thread: ThreadSnapshot, archived: Set<String>? = nil) -> Bool {
        if let keys = archived ?? archivedThreadKeys {
            let id = thread.isGroup ? String(thread.id.drop { $0 == "g" }) : thread.id
            return !keys.contains((thread.isGroup ? "g:" : "u:") + id)
        }
        return features.thread(thread.id)?.value["priority"]?.bool ?? true
    }
    /// Unread conversations in the tab that is not shown, for the dot on its label.
    func unreadCount(priority: Bool) -> Int {
        let archived = archivedThreadKeys
        return threads.filter { !$0.hidden && $0.hasUnread && isPriority($0, archived: archived) == priority }.count
    }
    private struct FilterKey: Equatable {
        let search:String, filter:ThreadFilter, priority:String, category:String
        let unread:Bool
        let selected:String?
        let opened:Set<String>
    }
    private var filterCache:(key:FilterKey,rows:[ThreadSnapshot])?
    var filteredThreads: [ThreadSnapshot] {
        let key=FilterKey(search:searchText,filter:filter,priority:priorityFilter,category:selectedCategory,unread:unreadOnly,selected:selectedThreadID,opened:recentlyOpenedIDs)
        if let cached=filterCache,cached.key==key { return cached.rows }
        let archived=archivedThreadKeys
        let result=threads.filter { thread in
            !thread.hidden &&
            (thread.lastMessageTimestamp > 0 || thread.id == selectedThreadID || recentlyOpenedIDs.contains(thread.id)) &&
            (!(features.thread(thread.id)?.flag("hidden") ?? false)) &&
            (priorityFilter == "all" || !searchText.isEmpty || isPriority(thread, archived: archived) == (priorityFilter == "priority")) &&
            (selectedCategory.isEmpty || features.thread(thread.id)?.string("category") == selectedCategory) &&
            (!unreadOnly || thread.hasUnread) &&
            (filter == .all || (filter == .groups ? thread.isGroup : !thread.isGroup)) &&
            (searchText.isEmpty || thread.name.localizedStandardContains(searchText) ||
             thread.lastMessage.localizedStandardContains(searchText))
        }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.lastMessageTimestamp != rhs.lastMessageTimestamp { return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        filterCache=(key,result)
        return result
    }
    var isSending: Bool {
        !busy.isDisjoint(with: ["send_message", "send_quote", "send_attachment", "send_sticker", "send_contact", "schedule_message"])
    }
    var canSend: Bool { ready && !isLocked && session.loggedIn && selectedThread != nil && !isSending }
    func supports(_ command: String) -> Bool { capabilities.contains(command) }

    func start() {
        guard !started else { return }
        started = true; generation += 1
        let currentGeneration = generation
        let process = CoreProcess(onEvent: { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.receive(event)
            }
        }, onFailure: { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.ready = false; self.busy.removeAll(); self.pending.removeAll()
                self.cancelTimeouts()
                self.connection = "Đã ngắt kết nối"; self.error = message
            }
        })
        bridge = process
        let environmentPath = ProcessInfo.processInfo.environment["CTDOZLITE_CORE_PATH"]
        let coreURL = environmentPath.map { URL(fileURLWithPath: $0) } ??
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ctdozlite-core")
        process.start(coreURL: coreURL, dataDirectory: dataDirectory, demo: demo)
    }

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        generation += 1; cancelTimeouts()
        if let bridge { bridge.stop(completion: completion) } else { completion() }
        bridge = nil; started = false
    }

    /// Restarts the worker; `prepare` runs off the main actor after it stopped and before it starts again.
    func restart(prepare: (@Sendable () -> Void)? = nil) {
        generation += 1
        let oldBridge = bridge
        bridge = nil; started = false
        ready = false; busy.removeAll(); pending.removeAll(); cancelTimeouts()
        session = SessionSnapshot(); AIBridgeSettings.shared.detach(); threads = []; messages = [:]; selectedThreadID = nil
        draft = ""; quote = nil; qrImage = nil; capabilities = []
        drafts.removeAll(); historyLimits.removeAll(); historyCursors.removeAll(); historyHasMore.removeAll(); historyHasNewer.removeAll(); removedMessageIDs.removeAll(); pageRequests.removeAll(); messageCacheOrder.removeAll(); lastHistoryRefresh.removeAll(); transcript.reset()
        resetExtras()
        connection = "Đang mở ứng dụng…"; error = nil
        profiles = [:]; threadLibraries = [:]; typing.reset(); sendBlocked = []; strangerBlocked = []; aliases = [:]; originalNames = [:]; aliasesRequested = false
        let launch: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                if let prepare { await Task.detached(priority: .userInitiated) { prepare() }.value }
                self?.start()
            }
        }
        if let oldBridge { oldBridge.stop(completion: launch) } else { launch() }
    }

    func selectThread(_ id: String?) {
        guard id == nil || threads.contains(where: { $0.id == id }) else { return }
        guard hiddenUnlocked || !threads.contains(where: { $0.id == id && $0.hidden }) else { error="Mở Hội thoại ẩn và xác thực trước khi xem cuộc trò chuyện này."; return }
        if id == selectedThreadID { return }
        conversationSearch = ""; showingConversationSearch = false
        suggestedStickers = []; pendingAttachments = []; highlightedMessageID = nil; jumpMessageID = nil
        selectingMessages = false; selectedMessageIDs.removeAll()
        if let id { recentlyOpenedIDs.insert(id) }
        error = nil
        if let previous = selectedThreadID { drafts[previous] = draft }
        selectedThreadID = id
        showingInspector = false
        transcript.activate(id,messages:messages[id ?? ""] ?? [])
        if id != nil { workspaceSection = .messages }
        draft = id.flatMap { drafts[$0] } ?? ""
        quote = nil
        guard let thread = selectedThread else { return }
        loadMessages(thread)

    }

    /// Only foreground reading at the latest message sends a read receipt.
    func markSelectedReadIfVisible() {
        // A closed or hidden window is not reading; never send "seen" from the background.
        guard !demo, !isLocked, workspaceSection == .messages, let thread = selectedThread,
              // The main window in front, or the small chat of a floating bubble open on this conversation.
              NSRunningApplication.current.isActive && BackgroundMode.mainWindowVisible || ChatHeads.shared.readingThreadID == thread.id,
              thread.hasUnread, supports("mark_seen"),
              !(messages[thread.id] ?? []).isEmpty, transcript.positions[thread.id]?.bottom != false,
              !pending.values.contains(where: { $0.command == "mark_seen" && $0.threadID == thread.id }) else { return }
        threadCommand("mark_seen", thread: thread)
    }

    func loadMessages(_ thread: ThreadSnapshot, more: Bool = false, newer: Bool = false) {
        if let diagnosticsPager { diagnosticsPager(thread, more, newer); return }
        guard supports("load_message_page") else {
            threadCommand("load_messages", thread: thread, parameters: ["limit": .number(Double(historyLimits[thread.id] ?? 200))])
            return
        }
        if !more && !newer && !(messages[thread.id] ?? []).isEmpty {
            // The worker pushes live messages only for the conversation it believes is open; tell it,
            // and receive anything that arrived while this cached conversation was in the background.
            if supports("select_thread") { threadCommand("select_thread", thread: thread) }
            refreshHistoryIfNeeded(thread)
            return
        }
        guard pageRequests[thread.id] == nil, !more || historyHasMore[thread.id] != false, !newer || historyHasNewer[thread.id] == true else { return }
        var parameters: [String: JSONValue] = ["thread_id": .string(thread.id), "is_group": .bool(thread.isGroup), "limit": .number(50)]
        if more, let cursor = historyCursors[thread.id] {
            parameters["before"] = .object(["timestamp": .number(Double(cursor.timestamp)), "id": .string(cursor.id)])
        }
        if newer, let last = messages[thread.id]?.last {
            parameters["after"] = .object(["timestamp": .number(last.timestamp), "id": .string(last.id)])
        }
        pageRequests[thread.id] = send("load_message_page", parameters: parameters, threadID: thread.id)
        if !more && !newer {
            // Remote refresh never sits on the path that supplies the first local frame.
            refreshHistoryIfNeeded(thread)
        }
    }

    private func refreshHistoryIfNeeded(_ thread:ThreadSnapshot) {
        guard Date().timeIntervalSince(lastHistoryRefresh[thread.id] ?? .distantPast)>15, !pending.values.contains(where:{$0.command=="load_messages" && $0.threadID==thread.id}) else{return}
        lastHistoryRefresh[thread.id]=Date()
        threadCommand("load_messages",thread:thread,parameters:["limit":.number(50)])
    }

    /// Development-only: the frame probe serves synthetic history pages through the normal cache path.
    var diagnosticsPager: ((ThreadSnapshot, Bool, Bool) -> Void)?
    func diagnosticsIngest(_ rows: [MessageSnapshot], threadID: String, older: Bool) { cacheMessages(rows, threadID: threadID, older: older) }

    func showLatest(_ thread: ThreadSnapshot) {
        if let request=pageRequests.removeValue(forKey:thread.id) {
            pending[request]=nil;timeouts.removeValue(forKey:request)?.cancel()
            if !pending.values.contains(where:{$0.command=="load_message_page"}) {busy.remove("load_message_page")}
        }
        messages[thread.id] = nil; historyCursors[thread.id] = nil; historyHasNewer[thread.id] = false
        transcript.positions[thread.id] = nil
        transcript.activate(thread.id, messages: [])
        loadMessages(thread)
    }

    private func cacheMessages(_ rows: [MessageSnapshot], threadID: String, older: Bool = false) {
        let limited: [MessageSnapshot]
        if let target=pendingJump, target.threadID==threadID, let index=rows.firstIndex(where:{$0.id==target.messageID}) {
            let start=max(0,index-200),end=min(rows.count,start+400)
            limited=Array(rows[start..<end]);historyHasNewer[threadID]=end<rows.count
        } else {limited = older ? Array(rows.prefix(400)) : Array(rows.suffix(400))}
        if older && rows.count>400 {historyHasNewer[threadID]=true}
        if !older && rows.count>400 {historyHasMore[threadID]=true}
        if let first=limited.first {historyCursors[threadID]=HistoryCursor(timestamp:(Int64(exactly:first.timestamp) ?? 0),id:first.id)}
        if messages[threadID] != limited {
            messages[threadID] = limited
            if threadID == selectedThreadID { transcript.replace(limited) }
        }
        messageCacheOrder.removeAll { $0 == threadID }; messageCacheOrder.append(threadID)
        while messageCacheOrder.count > 12 {
            let expired = messageCacheOrder.removeFirst()
            if expired != selectedThreadID { messages[expired] = nil; historyCursors[expired] = nil; historyHasMore[expired] = nil; historyHasNewer[expired] = nil }
        }
    }

    func sendText() {
        guard canSend, let thread = selectedThread, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard validDraftLength() else { return }
        let command = quote == nil ? "send_message" : "send_quote"
        guard supports(command) else { return }
        var parameters: [String: JSONValue] = ["thread_id": .string(thread.id), "is_group": .bool(thread.isGroup), "text": .string(draft)]
        if let quote { parameters["message_id"] = .string(quote.id) }
        if thread.isGroup, quote == nil, let chosen = draftMentions[thread.id], !chosen.isEmpty {
            let ranges = ComposerAssistText.mentionRanges(draft, chosen: chosen)
            if !ranges.isEmpty {
                parameters["mentions"] = .array(ranges.map { .object(["uid": .string($0.uid), "pos": .number(Double($0.pos)), "len": .number(Double($0.len))]) })
            }
        }
        send(command, parameters: parameters, threadID: thread.id, submittedText: draft)
    }

    func chooseAttachment() {
        guard canSend, let thread = selectedThread, supports("send_attachment") else { return }
        let panel = NSOpenPanel()
        panel.title = "Chọn tệp để gửi"; panel.prompt = "Gửi tệp"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                // Files wait in the composer so the person confirms the recipient before anything is sent.
                guard let self, self.selectedThreadID == thread.id else { return }
                self.addAttachments(urls)
            }
        }
    }

    func messageAction(_ command: String, message: MessageSnapshot, reaction: String? = nil) {
        guard let thread = selectedThread, supports(command) else { return }
        var parameters: [String: JSONValue] = ["message_id": .string(message.id)]
        if let reaction { parameters["reaction"] = .string(reaction) }
        threadCommand(command, thread: thread, parameters: parameters)
    }

    func openStickers() {
        guard supports("sticker_packs") else { return }
        showingStickers = true
        send("sticker_packs")
    }

    func sendSticker(_ sticker: StickerItem) {
        guard canSend, let thread = selectedThread else { return }
        threadCommand("send_sticker", thread: thread, parameters: [
            "sticker_id": .number(Double(sticker.stickerID)), "cate_id": .number(Double(sticker.categoryID)),
            "sticker_type": .number(Double(sticker.stickerType))
        ])
    }

    func openForward(_ message: MessageSnapshot) {
        forwardQueue = [message]
        forwardMessage = message; forwardSourceThread = selectedThread; showingForward = true
    }

    func forward(to target: ThreadSnapshot) {
        guard let message = forwardMessage, let source = forwardSourceThread else { return }
        for item in forwardQueue.isEmpty ? [message] : forwardQueue {
            // The core forwards text and stickers; photos, videos and files are sent again as attachments.
            if item.messageType != "chat.sticker", supports("send_attachment"), let media = ForwardMedia.source(item) {
                ForwardMedia.prepare(media, message: item) { [weak self] file in
                    guard let self, let file else { self?.error = "Không tải được tệp để chuyển tiếp. Hãy thử lại."; return }
                    self.send("send_attachment", parameters: ["thread_id": .string(target.id), "is_group": .bool(target.isGroup),
                        "path": .string(file.path), "caption": .string(ForwardMedia.caption(item))], threadID: target.id)
                }
                continue
            }
            threadCommand("forward_message", thread: source, parameters: ["message_id": .string(item.id),
                "target_thread_id": .string(target.id), "target_is_group": .bool(target.isGroup)])
        }
    }

    func schedule(at date: Date) {
        guard canSend, let thread = selectedThread, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard validDraftLength() else { return }
        var values: [String: JSONValue] = ["thread_id": .string(thread.id), "is_group": .bool(thread.isGroup),
                                          "text": .string(draft), "deliver_at": .number(date.timeIntervalSince1970.rounded(.down))]
        values["text"] = .string(draft)
        send("schedule_message", parameters: values, threadID: thread.id, submittedText: draft)
    }

    func chooseHistoryImport() {
        guard supports("import_history") else { return }
        let panel = NSOpenPanel()
        panel.title = "Chọn bản sao lịch sử"; panel.prompt = "Nhập lịch sử"
        panel.message = "Chọn tệp backup_zalo_….zl.zip do Zalo xuất, hoặc tệp/thư mục lịch sử .db, .sqlite, .json."
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self, self.importProgress == nil else { return }
                self.importSummary = nil; self.importRows = 0
                // Photos, videos and files come along only when chosen; they can take several GB.
                let media = UserDefaults.standard.bool(forKey: "nativeImportMedia")
                if self.send("import_history", parameters: ["path": .string(url.path), "include_media": .bool(media)]) != nil {
                    self.importProgress = 0; self.importPhase = "messages"
                }
            }
        }
    }

    func threadCommand(_ command: String, thread: ThreadSnapshot, parameters: [String: JSONValue] = [:]) {
        var values = parameters
        values["thread_id"] = .string(thread.id); values["is_group"] = .bool(thread.isGroup)
        send(command, parameters: values, threadID: thread.id)
    }

    @discardableResult
    func send(_ command: String, parameters: [String: JSONValue] = [:], threadID: String? = nil, submittedText: String? = nil) -> String? {
        guard ready, !isLocked || ["shutdown", "logout"].contains(command) else { return nil }
        let id = UUID().uuidString
        pending[id] = Pending(command: command, threadID: threadID, submittedText: submittedText)
        busy.insert(command)
        bridge?.send(id: id, command: command, parameters: parameters)
        // A multi-gigabyte export is bounded by its own progress and cancel, not by a short timer.
        let duration: UInt64 = ["request_qr": 420, "sync_history": 900, "import_history": 43_200,
                                "send_attachment": 300][command] ?? 150
        timeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: duration * 1_000_000_000) }
            catch { return }
            guard let self, let action = self.pending.removeValue(forKey: id) else { return }
            self.timeouts[id] = nil
            if action.command=="load_message_page", let threadID=action.threadID,self.pageRequests[threadID]==id {self.pageRequests[threadID]=nil}
            if !self.pending.values.contains(where: { $0.command == action.command }) { self.busy.remove(action.command) }
            self.error = action.submittedText == nil ? "Thao tác mất quá nhiều thời gian. Hãy kiểm tra kết nối rồi thử lại." :
                "Chưa nhận được xác nhận gửi. Hãy kiểm tra cuộc trò chuyện trước khi gửi lại."
        }
        return id
    }

    func chooseDataDirectory() {
        guard !demo else { return }
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục dữ liệu Zalo"; panel.prompt = "Sử dụng thư mục"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.proposedDataDirectory = url
                self?.showingDataFolderConfirmation = true
            }
        }
    }

    func applyDataDirectory() {
        guard let proposedDataDirectory else { return }
        dataDirectory = proposedDataDirectory
        UserDefaults.standard.set(dataDirectory.path, forKey: "nativeDataDirectory")
        self.proposedDataDirectory = nil
        restart()
    }

    func receive(_ event: CoreEvent) {
        do {
            switch event.event {
            case "ready":
                guard event.data?["protocol_version"]?.number == 1 else {
                    error = "Phiên bản bộ xử lý không tương thích. Hãy cập nhật ứng dụng đầy đủ."
                    bridge?.stop(); return
                }
                if case .array(let commands) = event.data?["capabilities"] {
                    capabilities = Set(commands.compactMap(\.string))
                }
                ready = true; connection = "Đang nạp dữ liệu…"; send("bootstrap")
            case "session":
                let next = try event.data?.decode(SessionSnapshot.self) ?? SessionSnapshot()
                // The worker answered for the account switched to: signed in, or asking for a QR code.
                switchingTo = nil
                savedAccountsCache = nil
                if !next.loggedIn || next.uin != session.uin {
                    cancelTimeouts(); pending.removeAll(); busy.removeAll()
                    drafts.removeAll(); historyLimits.removeAll(); historyCursors.removeAll(); historyHasMore.removeAll(); historyHasNewer.removeAll(); removedMessageIDs.removeAll(); pageRequests.removeAll(); messageCacheOrder.removeAll(); lastHistoryRefresh.removeAll(); transcript.reset()
                    receivedThreadSnapshot = false
                    AIBridgeSettings.shared.detach(); threads = []; messages = [:]; selectedThreadID = nil; draft = ""; quote = nil
                    resetExtras()
                }
                session = next
                if session.loggedIn {
                    // Names learnt earlier for this account fill a session that arrives without them.
                    let known = AccountNames.lookup(session.uin)
                    if session.name.isEmpty, let name = known.name { session.name = name }
                    if safeWebURL(session.avatar) == nil, let avatar = known.avatar { session.avatar = avatar }
                    AccountNames.remember(session)
                    sendBlocked = BlockedBy.load(account: session.uin)
                    if supports("list_blocked_contacts"), !busy.contains("list_blocked_contacts") { send("list_blocked_contacts") }
                    if session.name.isEmpty || safeWebURL(session.avatar) == nil { requestOwnProfile() }
                    qrImage = nil; connection = demo ? "Bản xem trước" : "Đã đăng nhập"
                    reloadWorkspaceFeatures()
                    if !demo { AIBridgeSettings.shared.attach(account: session.uin, ownerName: session.name, directory: dataDirectory, threads: threads) }
                    if supports("get_privacy_guard") { send("get_privacy_guard") }
                }
                else {
                    AIBridgeSettings.shared.detach(); threads = []; messages = [:]; selectedThreadID = nil; draft = ""; quote = nil
                    connection = "Chưa đăng nhập"
                }
            case "threads":
                let previous = selectedThread
                let hadSnapshot = receivedThreadSnapshot
                receivedThreadSnapshot = true
                let previousUnread = Dictionary(threads.map { ($0.id, $0.unread) }, uniquingKeysWith: { first, _ in first })
                let incoming = try event.preparedThreads ?? event.data?.decode([ThreadSnapshot].self) ?? []
                var unique: [String: ThreadSnapshot] = [:]
                for thread in incoming { unique[thread.id] = thread }
                // Names learnt from profiles outlive each fresh server snapshot.
                let next = applyProfileNames(unique.values.sorted { $0.id < $1.id })
                prefetchProfilesForUnnamedThreads(next)
                if !aliasesRequested, session.loggedIn, supports("list_aliases") { aliasesRequested = true; send("list_aliases") }
                if threads == next { break }
                threads = next
                if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) {
                    // A fresh server snapshot can replace a session-scoped conversation ID.
                    // Never keep sending intents for a row that no longer exists.
                    selectThread(nil)
                } else if let previous, let current = selectedThread, previous.isGroup != current.isGroup {
                    loadMessages(current)
                }
                if demo && selectedThreadID == nil, let first = filteredThreads.first { selectThread(first.id) }
                announceIncoming(previousUnread: previousUnread, hadSnapshot: hadSnapshot)
                // A live message usually lands before the snapshot that counts it as unread, so the open
                // conversation is marked read here too, as Zalo does while it is on screen.
                markSelectedReadIfVisible()
            case "messages", "message_page":
                if let snapshot = try event.preparedMessages ?? event.data?.decode(MessagesSnapshot.self) {
                    let isPage = event.event == "message_page"
                    if isPage {
                        guard let id = event.id, pageRequests[snapshot.threadID] == id,
                              demo || snapshot.account == session.uin else { break }
                        if snapshot.after != nil {historyHasNewer[snapshot.threadID] = snapshot.hasMore ?? false}
                        else {historyHasMore[snapshot.threadID] = snapshot.hasMore ?? false}
                        if snapshot.before != nil || historyCursors[snapshot.threadID] == nil {
                            historyCursors[snapshot.threadID] = snapshot.cursor
                        }
                    }
                    var unique = Dictionary((messages[snapshot.threadID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    // A live message while an older window is shown (after scrolling up or a quote jump):
                    // appending it could hide a gap, and dropping it lost it until the app restarted.
                    // Fetch forward from the last shown message instead; a closed thread just reloads fresh.
                    if !isPage, historyHasNewer[snapshot.threadID] == true,
                       snapshot.messages.contains(where: { unique[$0.id] == nil && !removedMessageIDs.contains($0.id) }) {
                        if snapshot.threadID == selectedThreadID {
                            if let thread = selectedThread { loadMessages(thread, newer: true) }
                        } else {
                            messages[snapshot.threadID] = nil; historyCursors[snapshot.threadID] = nil; historyHasNewer[snapshot.threadID] = nil
                        }
                    }
                    for message in snapshot.messages where !message.isOutgoing && unique[message.id] == nil {
                        typing.stop(thread: snapshot.threadID, user: message.senderID)
                    }
                    for message in snapshot.messages where !removedMessageIDs.contains(message.id) {
                        if isPage || historyHasNewer[snapshot.threadID] != true || unique[message.id] != nil {unique[message.id] = message}
                    }
                    let next = unique.values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
                    cacheMessages(next, threadID: snapshot.threadID, older: snapshot.before != nil)
                    if snapshot.threadID == selectedThreadID { resolveJump(); markSelectedReadIfVisible() }
                }
            case "account_unread":
                // Another saved account checked in the background (re-notes/77).
                if let data = event.data, let uin = data["uin"]?.string {
                    let checked = Date(timeIntervalSince1970: (data["checked_at"]?.number ?? Date().timeIntervalSince1970 * 1000) / 1000)
                    if let count = data["count"]?.number {
                        liveAccountUnread[uin] = AccountUnread(count: Int(count), asOf: checked, live: true)
                    } else if data["error"]?.string == "expired" {
                        liveAccountUnread[uin] = AccountUnread(count: 0, asOf: checked, live: true, expired: true)
                    }
                }
            case "typing":
                if let thread = event.data?["thread_id"]?.string, let user = event.data?["user_id"]?.string, user != session.uin {
                    typing.note(thread: thread, user: user)
                }
            case "message_removed":
                if let threadID = event.data?["thread_id"]?.string, let id = event.data?["message_id"]?.string {
                    removedMessageIDs.insert(id)
                    cacheMessages((messages[threadID] ?? []).filter { $0.id != id }, threadID: threadID)
                }
            case "qr":
                if let base64 = event.data?["image_base64"]?.string, base64.count <= 2 * 1_024 * 1_024,
                   let data = Data(base64Encoded: base64) {
                    // Decode outside the main actor because image parsing is bounded but still blocking work.
                    let currentGeneration = generation
                    Task { @MainActor [weak self] in
                        let image = await Task.detached { NSImage(data: data) }.value
                        guard let self, self.generation == currentGeneration else { return }
                        self.qrImage = image
                    }
                }
            case "status": if let message = event.data?["message"]?.string, message != connection { connection = message }
            case "result": handleResult(event)
            case "error": error = event.data?["message"]?.string ?? event.error ?? "Không thực hiện được thao tác."
            default: handleAdditionsEvent(event); handleBAEvent(event)
            }
        } catch { self.error = "Không đọc được dữ liệu. Hãy tải lại cuộc trò chuyện." }
    }

    private func handleResult(_ event: CoreEvent) {
        guard let id = event.id, let action = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        if action.command == "load_message_page", let threadID = action.threadID, pageRequests[threadID] == id { pageRequests[threadID] = nil }
        if !pending.values.contains(where: { $0.command == action.command }) { busy.remove(action.command) }
        let quiet = quietRequests.remove(id) != nil
        if event.ok != true {
            if quiet { return }
            if handleAdditionsFailure(command: action.command, requestID: id, threadID: action.threadID) { return }
            if event.error == Self.sendBlockedMessage, let threadID = action.threadID {
                // Shown as a bar above this conversation's composer instead of a generic banner.
                sendBlocked.insert(threadID); return
            }
            if event.error == Self.strangerBlockedMessage, let threadID = action.threadID {
                // Zalo shows this as a reply in the conversation; here it is the bar, with a friend request.
                strangerBlocked.insert(threadID); return
            }
            // Background reads for optional panels (group pins, media library) never raise a banner.
            if ["list_pinned_topics", "thread_library", "get_profile", "get_group_members", "select_thread", "list_blocked_contacts", "full_avatar"].contains(action.command) { return }
            // A late read failure must not cover a different conversation with an obsolete error.
            if ["load_messages", "load_message_page", "mark_seen"].contains(action.command), action.threadID != selectedThreadID { return }
            error = event.error ?? "Không thực hiện được thao tác. Hãy thử lại."
            return
        }
        if ["send_message", "send_quote", "send_attachment", "send_sticker", "send_contact"].contains(action.command), let threadID = action.threadID {
            sendBlocked.remove(threadID); strangerBlocked.remove(threadID)
        }
        handleBAResult(command: action.command, data: event.data, threadID: action.threadID, requestID: id)
        handleAdditionsResult(command: action.command, data: event.data, threadID: action.threadID, requestID: id)
        if action.command == "full_avatar", let user = event.data?["user_id"]?.string, let full = event.data?["url"]?.string,
           let url = safeWebURL(full) {
            let previous = fullAvatars[user]
            fullAvatars[user] = full
            // The viewer already shows the small photo; replace it in place with the original.
            if previous == nil { NotificationCenter.default.post(name: .replaceImageViewer, object: url) }
        }
        if action.command == "get_privacy_guard" || action.command == "set_privacy_guard" { privacyGuard = event.data }
        if ["get_account_settings", "set_account_setting", "set_two_factor"].contains(action.command) { accountSettings = event.data }
        if action.command == "list_media_devices" || action.command == "select_media_devices" { mediaDevices = event.data }
        if action.command == "poll_detail" || action.command == "poll_vote" { handlePollResult(event.data) }
        do {
            switch action.command {
            case "lookup_phone": contactResult = event.data
            case "get_profile": handleProfileResult(event.data)
            case "thread_library": handleLibraryResult(event.data)
            case "list_aliases":
                var next: [String: String] = [:]
                for row in event.data?["items"]?.featureRows ?? [] where !row.string("alias").isEmpty { next[row.string("user_id")] = row.string("alias") }
                aliases = next
                threads = applyProfileNames(threads)
            case "update_alias":
                // Zalo is the source of truth: reload nicknames and names after a change.
                send("list_aliases"); send("refresh_threads")
            case "add_friend": connection = "Đã gửi lời mời kết bạn"
            case "sticker_packs": stickerPacks = try event.data?["packs"]?.decode([StickerPack].self) ?? []
            case "sticker_pack", "search_stickers":
                let items = try event.data?["items"]?.decode([StickerItem].self) ?? []
                rememberStickerArt(items)
                // A background lookup for transcript animation must not replace the picker grid.
                if stickerArtRequests.remove(id) == nil { stickerItems = items }
            case "list_scheduled": scheduledMessages = try event.data?["items"]?.decode([ScheduledMessage].self) ?? []
            case "cancel_scheduled", "schedule_message": send("list_scheduled")
            case "forward_message": showingForward = false; send("refresh_threads")
            case "send_sticker": showingStickers = false
            case "import_history":
                importProgress = nil
                let added = Int(event.data?["messages_imported"]?.number ?? 0)
                var summary = "Đã nhập \(added) tin nhắn mới vào \(Int(event.data?["threads_imported"]?.number ?? 0)) hội thoại."
                if let seen = event.data?["messages_seen"]?.number {
                    summary += " Đã đọc \(Int(seen)) dòng"
                    let skipped = Int(event.data?["lines_skipped"]?.number ?? 0)
                    summary += skipped > 0 ? ", bỏ qua \(skipped) dòng không đọc được." : "."
                }
                if event.data?["cancelled"]?.bool == true { summary += " Bạn đã dừng giữa chừng; có thể nhập lại để tiếp tục, tin đã nhập không bị trùng." }
                if event.data?["media_imported"]?.bool == false { summary += " Ảnh, video và tệp trong bản sao lưu chưa được sao chép." }
                if event.data?["media_imported"]?.bool == true {
                    let linked = Int(event.data?["media_messages_linked"]?.number ?? 0)
                    let written = Int64(event.data?["media_bytes_written"]?.number ?? 0)
                    let present = Int(event.data?["media_files_present"]?.number ?? 0)
                    summary += " Đã gắn \(linked) ảnh, video, tệp vào tin nhắn (chép thêm \(ByteCountFormatter.string(fromByteCount: written, countStyle: .file))"
                    summary += present > 0 ? ", \(present) tệp đã có sẵn)." : ")."
                }
                importSummary = summary; connection = "Đã nhập \(added) tin nhắn"
                send("refresh_threads")
            default: break
            }
        } catch { self.error = "Không đọc được kết quả thao tác. Hãy tải lại dữ liệu." }
        if let text = action.submittedText, let threadID = action.threadID {
            if selectedThreadID == threadID && draft == text { draft = ""; quote = nil }
            if drafts[threadID] == text { drafts[threadID] = "" }
            if ["send_message", "send_quote"].contains(action.command) { draftMentions[threadID] = nil }
        }
        if ["send_message", "send_quote", "send_attachment", "send_sticker", "react", "recall_message", "delete_message"].contains(action.command),
           let thread = threads.first(where: { $0.id == action.threadID }) { loadMessages(thread) }
        if action.command == "logout" { qrImage = nil }
    }

    private func cancelTimeouts() {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
    }

    private func resetExtras() {
        transcript.activate(nil,messages:[])
        features = BAFeatureState(); workspaceSection = .messages
        selectedMessageIDs.removeAll(); selectingMessages = false; messageDetails = nil
        recentlyOpenedIDs.removeAll(); copyImageRequests.removeAll(); privacyGuard = nil; mediaDevices = nil; accountSettings = nil
        stickerPacks = []; stickerItems = []; scheduledMessages = []
        contactResult = nil; showingContactLookup = false; conversationSearch = ""; unreadOnly = false
        showingStickers = false; showingForward = false; showingScheduled = false
        forwardMessage = nil; forwardSourceThread = nil; forwardQueue = []
        jumpMessageID = nil; highlightedMessageID = nil; pendingJump = nil
        showingHistorySearch = false; showingConversationSearch = false; historyResults = []
        suggestedStickers = []; pendingAttachments = []; attachmentRequests.removeAll()
        discardTemporaryUploads()
        showingAccountInfo = false; addToGroupUser = nil; groupSeed = nil; blockCandidate = nil
        hiddenUnlocked = false; downloading = false
        importProgress = nil; importRows = 0; importSummary = nil
    }

    func validDraftLength() -> Bool {
        guard draft.utf8.count <= 20_000 else {
            error = "Tin nhắn quá dài. Hãy chia nội dung thành nhiều tin hoặc gửi dưới dạng tệp."
            return false
        }
        return true
    }
}


/// Text in the composer. Only the conversation's composer and its suggestions observe it; the
/// conversation list catches up once typing pauses, for the draft line under the open chat.
@MainActor
final class ComposerDraft: ObservableObject {
    @Published var text = "" {
        didSet { if text != oldValue { scheduleListRefresh() } }
    }
    /// The store to nudge after a pause, so the list's draft preview follows without per-key redraws.
    weak var owner: AppStore?
    private var pause: Task<Void, Never>?

    private func scheduleListRefresh() {
        pause?.cancel()
        pause = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.owner?.objectWillChange.send()
        }
    }
}
