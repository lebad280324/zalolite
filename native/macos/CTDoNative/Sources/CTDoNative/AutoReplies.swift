import SwiftUI
import NativeBridge

// Automatic replies and scheduled sending (re-notes/79).

/// One of Zalo's own auto-reply rules (`/api/autoreply/list`).
struct ServerAutoReply: Equatable {
    var id: JSONValue?
    var enable = true
    var content = ""
    var startTime: Int64 = 0
    var endTime: Int64 = 0
    var recurrence: [String] = []
    var scope = 0
    var uids: [String] = []
    var key: String { id.map { "\($0)" } ?? "new" }

    init() {}
    init?(_ row: JSONValue) {
        guard case .object(let o) = row, let id = o["id"], id != .null else { return nil }
        self.id = id
        enable = o["enable"]?.bool ?? false
        content = o["content"]?.string ?? ""
        startTime = Int64(o["start_time"]?.number ?? 0)
        endTime = Int64(o["end_time"]?.number ?? 0)
        if case .array(let r)? = o["recurrence"] { recurrence = r.compactMap(\.string) }
        scope = Int(o["scope"]?.number ?? 0)
        if case .array(let u)? = o["uids"] { uids = u.compactMap { $0.string ?? $0.number.map { String(Int64($0)) } } }
    }

    var parameters: [String: JSONValue] {
        var p: [String: JSONValue] = [
            "enable": .bool(enable), "content": .string(content),
            "start_time": .number(Double(startTime)), "end_time": .number(Double(endTime)),
            "recurrence": .array(recurrence.map(JSONValue.string)), "scope": .number(Double(scope)),
            "uids": .array(uids.map(JSONValue.string)),
        ]
        if let id { p["rule_id"] = id }
        return p
    }
}

/// Zalo PC's time window helpers (`73eU` in `compact-app-pc.js`): a rule is a daily window given as
/// two offsets from local midnight; the server stores it as absolute times anchored at yesterday.
enum AutoReplyTime {
    static let day: Int64 = 86_400_000
    /// Zalo PC presets (`autoReplies.presets`): all day, lunch, evening to morning.
    static let presets: [(String, Int64, Int64)] = [("Cả ngày", 0, 0), ("12:00 – 13:30", 43_200_000, 48_600_000), ("18:00 – 07:30", 64_800_000, 27_000_000)]

    static func isAllDay(_ start: Int64, _ end: Int64) -> Bool { let gap = abs(start - end); return gap >= day || gap < 1_000 }

    /// `S(e, t)`: offsets → `[startTime, endTime]`.
    static func absolute(start: Int64, end: Int64, now: Date = Date(), calendar: Calendar = .current) -> (Int64, Int64) {
        let base = Int64(calendar.startOfDay(for: now.addingTimeInterval(-86_400)).timeIntervalSince1970 * 1000)
        var finish = end
        if isAllDay(start, end) { finish = start + day } else if start > end { finish += day }
        return (base + start, base + finish)
    }

    /// `R([e, t])`: absolute times → local time-of-day offsets.
    static func offsets(start: Int64, end: Int64, calendar: Calendar = .current) -> (Int64, Int64) {
        func offset(_ ms: Int64) -> Int64 {
            let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return Int64(parts.hour ?? 0) * 3_600_000 + Int64(parts.minute ?? 0) * 60_000
        }
        return (offset(start), offset(end))
    }

    static func clock(_ offset: Int64) -> String { String(format: "%02d:%02d", offset / 3_600_000, (offset / 60_000) % 60) }

    static func label(start: Int64, end: Int64) -> String {
        let (a, b) = offsets(start: start, end: end)
        if isAllDay(a, b) { return "Cả ngày" }
        return "\(clock(a)) – \(clock(b))" + (a > b ? " (hôm sau)" : "")
    }
}

struct KeywordReplyRule: Identifiable, Equatable {
    var id = UUID().uuidString
    var keyword = ""
    var matchMode = "contains"
    var replyText = ""
    var enabled = true
    var scope = "all"

    var json: JSONValue {
        .object(["id": .string(id), "keyword": .string(keyword), "match_mode": .string(matchMode),
                 "reply_text": .string(replyText), "enabled": .bool(enabled), "scope": .string(scope)])
    }
}

struct KeywordReplySettings: Equatable {
    var enabled = false
    var includeGroups = false
    var cooldownMinutes = 180
    var rules: [KeywordReplyRule] = []

    init() {}
    init?(_ data: JSONValue?) {
        guard case .object(let o)? = data else { return nil }
        enabled = o["enabled"]?.bool ?? false
        includeGroups = o["include_groups"]?.bool ?? false
        cooldownMinutes = Int(o["cooldown_minutes"]?.number ?? 180)
        if case .array(let rows)? = o["rules"] {
            rules = rows.compactMap { row in
                guard case .object(let r) = row else { return nil }
                return KeywordReplyRule(id: r["id"]?.string ?? UUID().uuidString, keyword: r["keyword"]?.string ?? "",
                                        matchMode: r["match_mode"]?.string ?? "contains", replyText: r["reply_text"]?.string ?? "",
                                        enabled: r["enabled"]?.bool ?? true, scope: r["scope"]?.string ?? "all")
            }
        }
    }

    var parameters: [String: JSONValue] {
        ["enabled": .bool(enabled), "include_groups": .bool(includeGroups),
         "cooldown_minutes": .number(Double(cooldownMinutes)), "rules": .array(rules.map(\.json))]
    }
}

extension AppStore {
    /// Results of the auto-reply commands; returns true when the command was one of them.
    func handleAutoReplyResult(command: String, data: JSONValue?) -> Bool {
        switch command {
        case "server_auto_replies", "save_server_auto_reply", "delete_server_auto_reply":
            if case .object(let o)? = data, case .array(let rows)? = o["rules"] { serverAutoReplies = rows.compactMap(ServerAutoReply.init) }
            serverAutoReplyError = nil; serverAutoRepliesLoaded = true
            if command != "server_auto_replies" { connection = "Đã lưu trả lời tự động" }
            return true
        case "keyword_replies", "save_keyword_replies":
            keywordReplies = KeywordReplySettings(data)
            if command == "save_keyword_replies" { connection = "Đã lưu trả lời theo từ khóa" }
            return true
        default: return false
        }
    }
}

// MARK: - Settings page

struct AutomationSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var editingServer: ServerAutoReply?
    @State private var deletingServer: ServerAutoReply?
    @State private var keyword = KeywordReplySettings()
    @State private var editingRule: KeywordReplyRule?
    @State private var showingScheduled = false

    var body: some View {
        Group {
            serverSection
            keywordSection
            Section("Hẹn giờ gửi tin") {
                Text("Soạn tin trong một cuộc trò chuyện, bấm + → Hẹn giờ gửi rồi chọn thời gian. Tin được gửi khi Zalolite đang chạy và có mạng; nếu máy tắt hoặc ngủ đúng giờ hẹn, tin được gửi ngay khi Zalolite kết nối lại.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Xem tin nhắn hẹn giờ…") { store.send("list_scheduled"); showingScheduled = true }
                    .disabled(!store.session.loggedIn || !store.supports("list_scheduled"))
            }
        }
        .task {
            guard store.session.loggedIn else { return }
            if store.supports("server_auto_replies") { store.send("server_auto_replies") }
            if store.supports("keyword_replies") { store.send("keyword_replies") }
        }
        .onValueChange(of: store.keywordReplies) { _, value in if let value { keyword = value } }
        .onAppear { if let value = store.keywordReplies { keyword = value } }
        .sheet(item: Binding(get: { editingServer.map { Identified(value: $0) } }, set: { editingServer = $0?.value })) { item in
            ServerAutoReplyEditor(rule: item.value) { rule in store.send("save_server_auto_reply", parameters: rule.parameters) }
                .environmentObject(store)
        }
        .sheet(item: Binding(get: { editingRule.map { Identified(value: $0) } }, set: { editingRule = $0?.value })) { item in
            KeywordRuleEditor(rule: item.value) { rule in
                if let index = keyword.rules.firstIndex(where: { $0.id == rule.id }) { keyword.rules[index] = rule } else { keyword.rules.append(rule) }
                saveKeywords()
            }
        }
        .sheet(isPresented: $showingScheduled) { ScheduledMessagesView().environmentObject(store) }
        .confirmationDialog("Xóa trả lời tự động này?", isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } })) {
            Button("Xóa", role: .destructive) {
                if let id = deletingServer?.id { store.send("delete_server_auto_reply", parameters: ["rule_id": id]) }
                deletingServer = nil
            }
        } message: { Text("Zalo sẽ ngừng tự trả lời theo quy tắc này trên mọi thiết bị.") }
    }

    @ViewBuilder private var serverSection: some View {
        Section {
            Text("Do máy chủ Zalo gửi, nên vẫn trả lời khi Mac tắt. Đồng bộ với Zalo PC và điện thoại. Chỉ tài khoản có gói Zalo Business bật Trả lời tự động mới dùng được.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.serverAutoReplyError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                Button("Thử lại") { store.send("server_auto_replies") }
            } else if !store.serverAutoRepliesLoaded {
                ProgressView().controlSize(.small)
            } else {
                if store.serverAutoReplies.isEmpty { Text("Chưa có tin trả lời tự động nào.").foregroundStyle(.secondary) }
                ForEach(store.serverAutoReplies, id: \.key) { rule in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.content).lineLimit(2)
                            Text("\(AutoReplyTime.label(start: rule.startTime, end: rule.endTime)) · \(ServerAutoReplyEditor.scopes.first { $0.0 == rule.scope }?.1 ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { rule.enable }, set: { value in
                            var next = rule; next.enable = value
                            store.send("save_server_auto_reply", parameters: next.parameters)
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Menu { Button("Sửa…") { editingServer = rule }; Button("Xóa…", role: .destructive) { deletingServer = rule } } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                Button("Thêm trả lời tự động…") { editingServer = ServerAutoReply() }
            }
        } header: { Text("Trả lời tự động của Zalo") }
    }

    @ViewBuilder private var keywordSection: some View {
        Section {
            Toggle("Tự trả lời khi tin nhắn chứa từ khóa", isOn: $keyword.enabled.onSet(saveKeywords))
            Text("Zalolite tự gửi trả lời từ tài khoản của bạn khi đang chạy và có mạng. Zalo PC không có tính năng này; trả lời quá nhiều có thể bị Zalo xem là tin rác, nên mỗi cuộc trò chuyện chỉ nhận một tin trong khoảng chờ bên dưới, và chỉ tin nhắn đến trong 2 phút gần nhất mới được trả lời.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Trả lời cả trong nhóm", isOn: $keyword.includeGroups.onSet(saveKeywords))
            Picker("Mỗi cuộc trò chuyện chờ", selection: $keyword.cooldownMinutes.onSet(saveKeywords)) {
                ForEach([15, 30, 60, 180, 360, 720, 1440], id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) phút" : "\(minutes / 60) giờ").tag(minutes)
                }
            }
            ForEach(keyword.rules) { rule in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“\(rule.keyword)” → \(rule.replyText)").lineLimit(2)
                        Text("\(KeywordRuleEditor.modes.first { $0.0 == rule.matchMode }?.1 ?? "") · \(KeywordRuleEditor.scopes.first { $0.0 == rule.scope }?.1 ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in
                        if let index = keyword.rules.firstIndex(where: { $0.id == rule.id }) { keyword.rules[index].enabled = value; saveKeywords() }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Menu {
                        Button("Sửa…") { editingRule = rule }
                        Button("Xóa", role: .destructive) { keyword.rules.removeAll { $0.id == rule.id }; saveKeywords() }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            Button("Thêm từ khóa…") { editingRule = KeywordRuleEditor.newRule() }.disabled(keyword.rules.count >= 50)
        } header: { Text("Trả lời theo từ khóa") }
        .disabled(!store.session.loggedIn || !store.supports("save_keyword_replies"))
    }

    private func saveKeywords() { store.send("save_keyword_replies", parameters: keyword.parameters) }
}

private struct Identified<Value>: Identifiable {
    let value: Value
    let id = UUID()
}

private extension Binding {
    /// Runs `action` after each change, for settings that save immediately.
    func onSet(_ action: @escaping () -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}

struct ServerAutoReplyEditor: View {
    static let scopes: [(Int, String)] = [(0, "Tất cả mọi người"), (1, "Người chưa là bạn bè"), (2, "Chỉ một số bạn bè"), (3, "Bạn bè trừ một số người")]
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var rule: ServerAutoReply
    let onSave: (ServerAutoReply) -> Void
    @State private var start: Int64 = 0
    @State private var end: Int64 = 0
    @State private var friendQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule.id == nil ? "Tạo trả lời tự động" : "Sửa trả lời tự động").font(.title3.weight(.semibold))
            Text("Nội dung tin").font(.headline)
            TextEditor(text: $rule.content).font(.body).frame(height: 90).scrollContentBackground(.hidden)
                .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) { Text("\(rule.content.count)/2000").font(.caption2).foregroundStyle(rule.content.count > 2000 ? .red : .secondary).padding(6) }
            if rule.content.isEmpty { Text("VD: Mình đang họp, sẽ trả lời bạn sau 30 phút.").font(.caption).foregroundStyle(.secondary) }
            Text("Gửi trả lời trong khoảng thời gian").font(.headline)
            HStack {
                ForEach(AutoReplyTime.presets, id: \.0) { preset in
                    Button(preset.0) { start = preset.1; end = preset.2 }
                        .buttonStyle(.bordered).tint(start == preset.1 && end == preset.2 ? .accentColor : .secondary)
                }
            }
            HStack {
                timePicker("Từ", $start); timePicker("đến", $end)
                if AutoReplyTime.isAllDay(start, end) { Text("Cả ngày").foregroundStyle(.secondary) } else if start > end { Text("hôm sau").foregroundStyle(.secondary) }
            }
            Text("Lặp lại mỗi ngày.").font(.caption).foregroundStyle(.secondary)
            Text("Gửi trả lời khi nhận được tin nhắn từ").font(.headline)
            Picker("", selection: $rule.scope) { ForEach(Self.scopes, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().pickerStyle(.radioGroup)
            if rule.scope >= 2 { friendPicker }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(rule.id == nil ? "Tạo" : "Lưu") {
                    var next = rule
                    (next.startTime, next.endTime) = AutoReplyTime.absolute(start: start, end: end)
                    if next.recurrence.isEmpty { next.recurrence = ["RRULE:FREQ=DAILY;"] }
                    if next.scope < 2 { next.uids = [] }
                    onSave(next); dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.content.count > 2000 || (rule.scope >= 2 && rule.uids.isEmpty))
            }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            if rule.startTime > 0 { (start, end) = AutoReplyTime.offsets(start: rule.startTime, end: rule.endTime) }
        }
    }

    private func timePicker(_ label: String, _ value: Binding<Int64>) -> some View {
        Picker(label, selection: value) {
            ForEach(0..<48, id: \.self) { step in Text(AutoReplyTime.clock(Int64(step) * 1_800_000)).tag(Int64(step) * 1_800_000) }
        }.fixedSize()
    }

    private var friendPicker: some View {
        let friends = store.threads.filter { !$0.isGroup && $0.id.allSatisfy(\.isNumber) }
            .filter { friendQuery.isEmpty || $0.name.localizedStandardContains(friendQuery) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Tìm bạn bè", text: $friendQuery).textFieldStyle(.roundedBorder)
            List(friends.prefix(300)) { thread in
                Toggle(thread.name, isOn: Binding(get: { rule.uids.contains(thread.id) }, set: { on in
                    if on { if rule.uids.count < 50 { rule.uids.append(thread.id) } } else { rule.uids.removeAll { $0 == thread.id } }
                }))
            }.frame(height: 150)
            Text("Đã chọn \(rule.uids.count)/50 người").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct KeywordRuleEditor: View {
    static let modes: [(String, String)] = [("contains", "Tin nhắn chứa từ khóa"), ("exact", "Tin nhắn đúng bằng từ khóa"), ("prefix", "Tin nhắn bắt đầu bằng từ khóa")]
    static let scopes: [(String, String)] = [("all", "Mọi cuộc trò chuyện"), ("direct", "Chỉ chat riêng"), ("group", "Chỉ nhóm")]
    static func newRule() -> KeywordReplyRule { KeywordReplyRule() }
    @Environment(\.dismiss) private var dismiss
    @State var rule: KeywordReplyRule
    let onSave: (KeywordReplyRule) -> Void

    var body: some View {
        Form {
            TextField("Từ khóa", text: $rule.keyword, prompt: Text("VD: giá, địa chỉ, giờ mở cửa"))
            Picker("Cách khớp", selection: $rule.matchMode) { ForEach(Self.modes, id: \.0) { Text($0.1).tag($0.0) } }
            Picker("Áp dụng cho", selection: $rule.scope) { ForEach(Self.scopes, id: \.0) { Text($0.1).tag($0.0) } }
            Section("Nội dung trả lời") { TextEditor(text: $rule.replyText).frame(height: 90) }
            Text("Không phân biệt chữ hoa, chữ thường. Nhóm chỉ được trả lời khi bật \"Trả lời cả trong nhóm\".").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).frame(width: 460, height: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Lưu") { onSave(rule); dismiss() }
                    .disabled(rule.keyword.trimmingCharacters(in: .whitespaces).isEmpty || rule.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.keyword.count > 200 || rule.replyText.count > 2000)
            }
        }
    }
}
