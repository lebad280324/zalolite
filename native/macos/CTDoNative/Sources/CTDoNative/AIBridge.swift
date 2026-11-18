import SwiftUI
import AppKit
import NativeBridge

/// Which conversations a local AI assistant may read through `ctdozlite-core --mcp`
/// (`src/ai_bridge.rs`). The choice is kept per account and written to `ai_bridge.json` in the
/// data directory, which the bridge re-reads on every request.
@MainActor final class AIBridgeSettings: ObservableObject {
    static let shared = AIBridgeSettings()
    static let enabledKey = "nativeAIBridgeEnabled"

    struct Item: Codable, Hashable, Identifiable {
        var id: String
        var isGroup: Bool
        var name: String
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: AIBridgeSettings.enabledKey)
    @Published private(set) var items: [Item] = []
    private var account = ""
    private var ownerName = ""
    private var directory: URL?

    /// Called when an account is signed in; refreshes shared names from the thread list.
    func attach(account: String, ownerName: String, directory: URL, threads: [ThreadSnapshot]) {
        self.account = account; self.ownerName = ownerName; self.directory = directory
        var loaded = (UserDefaults.standard.data(forKey: listKey)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        for index in loaded.indices {
            if let thread = threads.first(where: { $0.id == loaded[index].id && $0.isGroup == loaded[index].isGroup }), !thread.name.isEmpty {
                loaded[index].name = thread.name
            }
        }
        items = loaded
        write()
    }

    /// Signed out: the bridge refuses every request until an account is attached again.
    func detach() {
        account = ""; items = []
        write()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        write()
    }

    func isShared(_ thread: ThreadSnapshot) -> Bool { items.contains { $0.id == thread.id && $0.isGroup == thread.isGroup } }

    func toggle(_ thread: ThreadSnapshot) {
        if isShared(thread) { items.removeAll { $0.id == thread.id && $0.isGroup == thread.isGroup } }
        else { items.append(Item(id: thread.id, isGroup: thread.isGroup, name: thread.name)) }
        save()
    }

    func remove(_ item: Item) { items.removeAll { $0 == item }; save() }

    private var listKey: String { "nativeAIShared.\(account)" }

    private func save() {
        guard !account.isEmpty else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: listKey)
        write()
    }

    private func write() {
        guard let directory else { return }
        let body: [String: Any] = [
            "enabled": enabled && !account.isEmpty,
            "account": account,
            "owner_name": ownerName,
            "conversations": items.map { ["id": $0.id, "is_group": $0.isGroup, "name": $0.name] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        let file = directory.appendingPathComponent("ai_bridge.json")
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The bundled bridge executable and the data folder it reads.
    static func command(directory: URL) -> (core: String, data: String) {
        (Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ctdozlite-core").path, directory.path)
    }
}

/// Cài đặt → Trợ lý AI.
struct AIBridgeSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var bridge = AIBridgeSettings.shared
    @State private var picking = false
    @State private var copied = ""
    @State private var connected = AIAssistantConnections()

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cho phép trợ lý AI đọc hội thoại được chọn")
                    Text("Chỉ đọc. Trợ lý không gửi được tin nhắn và không thấy hội thoại khác.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Chia sẻ") } footer: {
            Text("Khi bạn hỏi, nội dung liên quan của các hội thoại này được gửi cho dịch vụ AI để phân tích.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            if bridge.items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Chưa chọn hội thoại nào. Chọn nhóm công việc hoặc người bạn muốn trợ lý theo dõi.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            ForEach(bridge.items) { item in
                AIConversationRow(item: item, thread: thread(for: item)) {
                    Button { withAnimation(.snappy(duration: 0.2)) { bridge.remove(item) } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 17)).foregroundStyle(.red.opacity(0.85))
                    }.buttonStyle(.borderless).help("Ngừng chia sẻ hội thoại này")
                }
            }
            Button { picking = true } label: { Label("Chọn hội thoại…", systemImage: "plus.circle") }
                .disabled(store.threads.isEmpty || !bridge.enabled)
        } header: {
            Text(bridge.items.isEmpty ? "Hội thoại được chia sẻ" : "Hội thoại được chia sẻ (\(bridge.items.count))")
        } footer: {
            Text("Cũng có thể nhấp chuột phải vào một hội thoại → Chia sẻ với trợ lý AI.").font(.caption).foregroundStyle(.secondary)
        }

        Section {
            let paths = AIBridgeSettings.command(directory: store.dataDirectory)
            connectionRow("Codex", icon: "chevron.left.forwardslash.chevron.right", connected: connected.codex)
            connectionRow("Claude Desktop", icon: "sparkle", connected: connected.claudeDesktop)
            if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                Label("Zalolite đang chạy ngoài thư mục Applications. Sau khi chuyển vào Applications, hãy chạy lại lệnh kết nối.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Lệnh kết nối thủ công") {
                VStack(alignment: .leading, spacing: 12) {
                    commandRow("Codex (app) — thêm vào ~/.codex/config.toml", codexTOML(paths))
                    commandRow("Codex (dòng lệnh)", "codex mcp add zalolite -- \(quote(paths.core)) --mcp --data-dir \(quote(paths.data))")
                    commandRow("Claude Code", "claude mcp add zalolite --scope user -- \(quote(paths.core)) --mcp --data-dir \(quote(paths.data))")
                    commandRow("Claude Desktop", desktopJSON(paths))
                }.padding(.top, 6)
            }
        } header: { Text("Kết nối với trợ lý") } footer: {
            Text("Sau khi kết nối, mở lại trợ lý rồi hỏi, ví dụ: “Đọc tin nhắn nhóm Kinh doanh 3 ngày qua, liệt kê việc tôi đã nhận mà chưa xong.”")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $picking) { AIConversationPicker().environmentObject(store) }
        .onAppear { connected = AIAssistantConnections() }
    }

    private func thread(for item: AIBridgeSettings.Item) -> ThreadSnapshot? {
        store.threads.first { $0.id == item.id && $0.isGroup == item.isGroup }
    }

    private func connectionRow(_ name: String, icon: String, connected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(name)
            Spacer()
            if connected {
                Label("Đã kết nối", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Text("Chưa kết nối").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private func commandRow(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(copied == title ? "Đã chép" : "Chép") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string); copied = title
                }.controlSize(.small)
            }
            Text(verbatim: command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func codexTOML(_ paths: (core: String, data: String)) -> String {
        func toml(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "[mcp_servers.zalolite]\ncommand = \(toml(paths.core))\nargs = [ \"--mcp\", \"--data-dir\", \(toml(paths.data)) ]\nstartup_timeout_sec = 15"
    }

    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func desktopJSON(_ paths: (core: String, data: String)) -> String {
        let object: [String: Any] = ["mcpServers": ["zalolite": ["command": paths.core, "args": ["--mcp", "--data-dir", paths.data]]]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Whether an assistant's own configuration already lists the Zalolite bridge.
struct AIAssistantConnections {
    var codex = false
    var claudeDesktop = false
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexConfig = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        codex = codexConfig.contains("[mcp_servers.zalolite]")
        let claudeConfig = (try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        claudeDesktop = (claudeConfig?["mcpServers"] as? [String: Any])?["zalolite"] != nil
    }
}

/// One conversation with its real avatar and a short description.
struct AIConversationRow<Accessory: View>: View {
    let item: AIBridgeSettings.Item
    let thread: ThreadSnapshot?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            if let thread { ThreadAvatar(thread: thread, size: 36) }
            else { AvatarView(name: item.name, url: nil, size: 36, group: item.isGroup) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name.isEmpty ? item.id : item.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(verbatim: AIConversationRow.subtitle(thread, isGroup: item.isGroup)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 3)
    }

    /// "Nhóm · 24 thành viên · 14:47" or "Cá nhân · Thứ Hai".
    static func subtitle(_ thread: ThreadSnapshot?, isGroup: Bool) -> String {
        var parts = [isGroup ? "Nhóm" : "Cá nhân"]
        if isGroup, let total = thread?.memberTotal, total > 0 { parts.append("\(total) thành viên") }
        if let thread, thread.lastMessageTimestamp > 0 { parts.append(stamp(thread.date)) }
        return parts.joined(separator: " · ")
    }

    static func stamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.defaultDigits).year(.twoDigits))
    }
}

/// Picker sheet: real avatars, chosen conversations on top, a Personal/Group filter.
struct AIConversationPicker: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var bridge = AIBridgeSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind = 0
    @State private var hovered: String?

    private func matches(_ thread: ThreadSnapshot) -> Bool {
        !thread.hidden
            && (kind == 0 || (kind == 2) == thread.isGroup)
            && (query.isEmpty || thread.name.localizedStandardContains(query))
    }
    private var candidates: [ThreadSnapshot] { store.threads.filter(matches).sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp } }

    var body: some View {
        let chosen = candidates.filter { bridge.isShared($0) }
        let others = candidates.filter { !bridge.isShared($0) }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chọn hội thoại cho trợ lý AI").font(.title3.weight(.semibold))
                    Text(bridge.items.isEmpty ? "Chưa chọn hội thoại nào" : "Đã chọn \(bridge.items.count) hội thoại")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Xong") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tìm hội thoại", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $kind) { Text("Tất cả").tag(0); Text("Cá nhân").tag(1); Text("Nhóm").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !chosen.isEmpty {
                        header("Đã chọn")
                        ForEach(chosen) { row($0) }
                    }
                    if !others.isEmpty {
                        header(chosen.isEmpty ? "Hội thoại" : "Hội thoại khác")
                        ForEach(others) { row($0) }
                    }
                    if chosen.isEmpty && others.isEmpty {
                        Text("Không có hội thoại khớp.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            Label("Trợ lý chỉ đọc được các hội thoại đã chọn.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
        }
        .frame(width: 500, height: 620)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ thread: ThreadSnapshot) -> some View {
        let shared = bridge.isShared(thread)
        let item = AIBridgeSettings.Item(id: thread.id, isGroup: thread.isGroup, name: thread.name)
        return Button { withAnimation(.snappy(duration: 0.18)) { bridge.toggle(thread) } } label: {
            AIConversationRow(item: item, thread: thread) {
                Image(systemName: shared ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(shared ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(shared ? Color.accentColor.opacity(0.10) : hovered == thread.id ? Color.primary.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? thread.id : (hovered == thread.id ? nil : hovered) }
        .accessibilityAddTraits(shared ? .isSelected : [])
    }
}
