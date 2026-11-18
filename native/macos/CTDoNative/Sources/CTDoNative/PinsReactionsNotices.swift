import SwiftUI
import AppKit
import NativeBridge

extension Notification.Name {
    /// Expands the pinned-messages bar of the open conversation.
    static let showPinnedList = Notification.Name("ctdozlite.showPinnedList")
}

// MARK: - Conversation library

/// Photos, files and links found in a conversation's whole local history.
struct ThreadLibrary {
    var photos: [MessageSnapshot]
    var files: [MessageSnapshot]
    var links: [MessageSnapshot]
    var scanned: Int
    var all: [MessageSnapshot] { photos + files + links }
}

extension AppStore {
    func requestThreadLibrary(_ thread: ThreadSnapshot) {
        guard supports("thread_library") else { return }
        threadCommand("thread_library", thread: thread)
    }

    func handleLibraryResult(_ data: JSONValue?) {
        guard let id = data?["thread_id"]?.string else { return }
        func rows(_ key: String) -> [MessageSnapshot] { (try? data?[key]?.decode([MessageSnapshot].self)) ?? [] }
        threadLibraries[id] = ThreadLibrary(photos: rows("photos"), files: rows("files"), links: rows("links"),
                                            scanned: Int(data?["scanned"]?.number ?? 0))
    }

    /// Name and avatar for a person ID inside a conversation: you, a group member, a known profile or a chat.
    func personIdentity(_ id: String, in thread: ThreadSnapshot?) -> (name: String, avatar: String?) {
        if !id.isEmpty, id == session.uin { return ("Bạn", nil) }
        let found = basePersonIdentity(id, in: thread)
        // A nickname set on Zalo replaces the name everywhere, as Zalo shows it.
        if let alias = aliases[id], !alias.isEmpty { return (alias, found.avatar) }
        return found
    }

    private func basePersonIdentity(_ id: String, in thread: ThreadSnapshot?) -> (name: String, avatar: String?) {
        if let thread, let member = features.members[thread.id]?.first(where: { $0.id == id }) {
            let avatar = member.string("avatar")
            return (member.string("name", "display_name"), avatar.isEmpty ? nil : avatar)
        }
        if let profile = profiles[id], let name = profile.name, !name.isEmpty { return (name, profile.avatar) }
        if let direct = threads.first(where: { $0.id == id && !$0.isGroup }) { return (direct.name, direct.avatar) }
        if let thread, !thread.isGroup, thread.id == id { return (thread.name, thread.avatar) }
        return ("Thành viên", nil)
    }
}

// MARK: - Reactions

/// Reactions under a bubble: the top emoji and total, tap to see who reacted.
/// The chip springs when the count changes and bursts when you add your own reaction.
struct ReactionChips: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let message: MessageSnapshot
    var fill: Color
    @State private var showingWho = false
    @State private var burst: String?

    static func details(_ message: MessageSnapshot) -> [ReactionDetail] {
        if !message.reactionDetails.isEmpty { return message.reactionDetails.filter { $0.count > 0 } }
        switch message.reactions {
        case .array(let values): return values.compactMap(\.string).map { ReactionDetail(emoji: $0, count: 1, reactors: []) }
        case .object(let values): return values.keys.sorted().map { ReactionDetail(emoji: $0, count: 1, reactors: []) }
        default: return []
        }
    }
    static func hasReactions(_ message: MessageSnapshot) -> Bool { !details(message).isEmpty }

    private var details: [ReactionDetail] { Self.details(message).sorted { $0.count > $1.count } }
    private var total: Int { details.reduce(0) { $0 + $1.count } }
    private var mine: String? { details.first { $0.reactors.contains(store.session.uin) }?.emoji }

    var body: some View {
        if !details.isEmpty {
            Button { showingWho.toggle() } label: {
                HStack(spacing: 1) {
                    ForEach(details.prefix(3), id: \.emoji) { Text($0.emoji).font(.system(size: 13)) }
                    if total > 1 {
                        Text("\(total)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(mine != nil ? Color.accentColor : .secondary)
                            .contentTransition(.numericText()).padding(.leading, 3)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(fill, in: Capsule())
                .overlay { Capsule().strokeBorder(mine != nil ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: mine != nil ? 1 : 0.5) }
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Xem ai đã thả cảm xúc")
            .reactionPop(trigger: total, reducedMotion: reducedMotion)
            .overlay {
                if let burst {
                    ReactionBurst(emoji: burst) { self.burst = nil }.allowsHitTesting(false)
                }
            }
            .onValueChange(of: mine) { old, new in
                if let new, new != old, !reducedMotion { burst = new }
            }
            .windowBoundedPopover(isPresented: $showingWho) {
                ReactorsList(message: message, details: details)
            }
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}

/// A large copy of the chosen emoji that pops up from the chip and fades away.
private struct ReactionBurst: View {
    let emoji: String
    let done: () -> Void
    @State private var phase = false
    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                let angle = Double(index) / 5 * 2 * .pi - .pi / 2
                Text(emoji).font(.system(size: 12))
                    .offset(x: phase ? cos(angle) * 26 : 0, y: phase ? sin(angle) * 26 : 0)
                    .opacity(phase ? 0 : 1)
            }
            Text(emoji).font(.system(size: 30))
                .scaleEffect(phase ? 1.6 : 0.4)
                .offset(y: phase ? -34 : 0)
                .opacity(phase ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.65)) { phase = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { done() }
        }
    }
}

/// Who reacted, grouped by emoji, like Zalo's reaction sheet.
private struct ReactorsList: View {
    @EnvironmentObject private var store: AppStore
    let message: MessageSnapshot
    let details: [ReactionDetail]
    @Environment(\.popoverMaxHeight) private var maxHeight
    @State private var filter: String?

    private var rows: [(id: String, emoji: String, times: Int)] {
        details.filter { filter == nil || $0.emoji == filter }
            .flatMap { detail in detail.reactors.enumerated().map { (id: $1, emoji: detail.emoji, times: detail.count(for: $0)) } }
    }
    private var mine: [String] { details.filter { $0.reactors.contains(store.session.uin) }.map(\.emoji) }
    private var unattributed: Int {
        details.filter { filter == nil || $0.emoji == filter }.reduce(0) { $0 + max(0, $1.count - $1.reactors.count) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cảm xúc").font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tab(nil, "Tất cả \(details.reduce(0) { $0 + $1.count })")
                    ForEach(details, id: \.emoji) { tab($0.emoji, "\($0.emoji) \($0.count)") }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let person = store.personIdentity(row.id, in: store.selectedThread)
                        HStack(spacing: 10) {
                            AvatarView(name: person.name, url: person.avatar, size: 30)
                            Text(verbatim: person.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 3) {
                                Text(row.emoji).font(.system(size: 17))
                                if row.times > 1 { Text("×\(row.times)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if unattributed > 0 {
                        Label(rows.isEmpty ? "Zalo chưa gửi danh sách người thả cảm xúc này." : "Và \(unattributed) lượt khác",
                              systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: min(320, max(90, maxHeight - (mine.isEmpty ? 110 : 160))))
            if !mine.isEmpty && store.supports("react") {
                Divider()
                Button(role: .destructive) { store.messageAction("react", message: message, reaction: "") } label: {
                    Label("Gỡ cảm xúc của bạn (\(mine.joined(separator: " ")))", systemImage: "heart.slash")
                        .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.red)
            }
        }
        .padding(14).frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        // Liquid Glass: the popover shows the conversation through it, like the system's own.
        .materialPresentationBackground()
    }

    private func tab(_ emoji: String?, _ title: String) -> some View {
        Button { withAnimation(.snappy(duration: 0.18)) { filter = emoji } } label: {
            Text(verbatim: title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(filter == emoji ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(filter == emoji ? Color.accentColor : .primary)
        }.buttonStyle(.plain)
    }
}

// MARK: - Group notices

/// "X đã rời khỏi nhóm" and pin notices as a centred pill, not a chat bubble.
struct GroupNoticePill: View {
    @EnvironmentObject private var store: AppStore
    let message: MessageSnapshot
    let thread: ThreadSnapshot

    private enum Kind { case pin, unpin, leave, join, other }
    private static let markers: [(String, Kind)] = [
        (" bỏ ghim 1 tin nhắn", .unpin), (" ghim 1 tin nhắn", .pin), (" đã rời khỏi nhóm", .leave), (" đã rời nhóm", .leave),
        (" đã tham gia nhóm", .join), (" đã được thêm vào nhóm", .join),
    ]
    private var text: String { message.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: (kind: Kind, actor: String, rest: String) {
        for (marker, kind) in Self.markers {
            if let range = text.range(of: marker) {
                return (kind, String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
            }
        }
        return (.other, "", text)
    }
    /// Avatar of the person named in a join/leave notice, matched against the member list by name.
    private var actorAvatar: String? {
        let actor = parsed.actor
        guard !actor.isEmpty else { return nil }
        let avatar = store.features.members[thread.id]?.first { $0.string("name", "display_name") == actor }?.string("avatar")
        return avatar?.isEmpty == false ? avatar : nil
    }

    var body: some View {
        let parsed = self.parsed
        HStack(spacing: 7) {
            switch parsed.kind {
            case .pin: Image(systemName: "pin.fill").foregroundStyle(.orange).rotationEffect(.degrees(35))
            case .unpin: Image(systemName: "pin.slash").foregroundStyle(.secondary)
            case .leave, .join: AvatarView(name: parsed.actor, url: actorAvatar, size: 20)
            case .other: Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            (Text(verbatim: parsed.actor).fontWeight(.semibold) + Text(verbatim: parsed.rest).foregroundColor(.secondary))
                .lineLimit(1).truncationMode(.tail)
            if parsed.kind == .pin {
                Button("Xem") { NotificationCenter.default.post(name: .showPinnedList, object: thread.id) }
                    .buttonStyle(.plain).foregroundStyle(.tint).fontWeight(.medium)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help(text)
    }
}

// MARK: - Pinned messages

/// One pinned message: a group pin from Zalo's board, or a pin kept on this Mac.
private struct PinItem: Identifiable {
    let id: String
    let text: String
    let sender: String
    let messageID: String
    let local: Bool
    var isLink: Bool { text.contains("http://") || text.contains("https://") }
}

/// Pinned messages under the header, collapsed to the newest one like Zalo, on Liquid Glass.
/// Groups show Zalo's server pins; every conversation also shows messages pinned on this Mac.
struct PinnedMessagesBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let thread: ThreadSnapshot
    @State private var expanded = false

    private var pins: [PinItem] {
        let server = thread.isGroup ? (store.features.pinnedTopics[thread.id] ?? []).enumerated().map { index, row in
            PinItem(id: "s:\(row.string("topic_id"))#\(index)", text: row.string("text", "title", "content"),
                    sender: row.string("sender_name"), messageID: row.string("message_id"), local: false)
        } : []
        let local = store.features.rows("pinned_messages").filter { $0.string("thread_id") == thread.id }
            .sorted { $0.number("timestamp") > $1.number("timestamp") }
            .map { row in
                PinItem(id: "l:\(row.string("message_id"))", text: row.string("text"), sender: row.string("sender"),
                        messageID: row.string("message_id"), local: true)
            }
        return (server + local).filter { !$0.text.isEmpty }
    }
    /// The newest pin notice; a new one means the server list changed.
    private var pinNoticeKey: String {
        store.selectedMessages.last { $0.messageType == "chat.system" && $0.text.contains("ghim 1 tin nhắn") }?.id ?? ""
    }

    var body: some View {
        let pins = self.pins
        Group {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    if expanded {
                        HStack {
                            Text("Danh sách ghim (\(pins.count))").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { expanded = false } label: { Label("Thu gọn", systemImage: "chevron.up").labelStyle(TrailingIcon()) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                                    if index > 0 { Divider().padding(.leading, 52).opacity(0.5) }
                                    row(pin)
                                }
                            }
                        }.frame(maxHeight: 240).fixedSize(horizontal: false, vertical: true)
                    } else if let first = pins.first {
                        row(first, more: pins.count - 1)
                    }
                }
                .nativeGlass(18)
                // A light tint under the glass keeps the text readable over busy messages and wallpapers.
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                .padding(.horizontal, 14).padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reducedMotion ? nil : .snappy(duration: 0.24), value: expanded)
        .animation(reducedMotion ? nil : .snappy(duration: 0.24), value: pins.count)
        .onAppear { refresh() }
        .onValueChange(of: thread.id) { _, _ in expanded = false; refresh() }
        .onValueChange(of: pinNoticeKey) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .showPinnedList)) { note in
            if note.object as? String == thread.id { expanded = true }
        }
    }

    private func refresh() {
        // Demo mode has no server pins to fetch.
        guard thread.isGroup, !store.demo, store.supports("list_pinned_topics") else { return }
        store.threadCommand("list_pinned_topics", thread: thread)
    }

    private func row(_ pin: PinItem, more: Int = 0) -> some View {
        let text = pin.text.replacingOccurrences(of: "\n", with: " ")
        return HStack(spacing: 12) {
            Image(systemName: pin.isLink ? "link" : "text.bubble").font(.system(size: 14, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 28, height: 28).background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.isLink ? "Liên kết" : "Tin nhắn").font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: pin.sender.isEmpty ? text : "\(pin.sender): \(text)").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if more > 0 {
                Button { expanded = true } label: {
                    HStack(spacing: 3) { Text("+\(more)"); Image(systemName: "chevron.down") }
                        .font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).help("Xem tất cả tin ghim")
            }
            Menu {
                if !pin.messageID.isEmpty { Button("Đến tin nhắn", systemImage: "arrow.right.circle") { store.jump(toThread: thread.id, messageID: pin.messageID) } }
                Button("Sao chép", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pin.text, forType: .string) }
                if pin.local, store.supports("pin_message_local") {
                    Divider()
                    Button("Bỏ ghim", systemImage: "pin.slash") {
                        store.featureThread("pin_message_local", thread: thread, values: ["message_id": .string(pin.messageID), "pinned": .bool(false)])
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Tùy chọn")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if !pin.messageID.isEmpty { store.jump(toThread: thread.id, messageID: pin.messageID) } }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.title; configuration.icon } }
}

// MARK: - Message details

/// Compact details card: preview, sender, time, type and ID, sized to its content.
struct MessageDetailsCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: MessageSnapshot

    private var identity: (name: String, avatar: String?) {
        if message.isOutgoing { return ("Bạn", nil) }
        if let thread = store.selectedThread {
            let found = store.senderIdentity(message, in: thread)
            return (found.name, found.avatar)
        }
        return (message.senderName, nil)
    }
    private var kind: String {
        switch message.messageType {
        case "chat.photo": return "Hình ảnh"
        case "chat.video.msg": return "Video"
        case "share.file": return "Tệp"
        case "chat.sticker": return "Nhãn dán"
        case "chat.location": return "Vị trí"
        case "chat.system": return "Thông báo nhóm"
        default: return MediaPresentation.showsLinkPreview(message) ? "Liên kết" : "Văn bản"
        }
    }
    private var preview: String {
        let caption = MediaPresentation.caption(message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { return caption }
        return MediaPresentation.fileName(message) ?? message.linkTitle ?? "[\(kind)]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(name: identity.name, url: identity.avatar, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: identity.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(message.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second())
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Đóng (Esc)")
            }
            Text(verbatim: preview).font(.system(size: 13.5)).lineLimit(8).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(spacing: 0) {
                field("Loại", kind)
                Divider()
                field("Mã tin", message.id, copy: true, mono: true)
                if !ReactionChips.details(message).isEmpty {
                    Divider()
                    field("Cảm xúc", ReactionChips.details(message).map { "\($0.emoji) \($0.count)" }.joined(separator: "  "))
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18).frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ title: String, _ value: String, copy: Bool = false, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(verbatim: value).font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
            if copy {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Sao chép")
            }
        }.padding(.vertical, 8)
    }
}

// MARK: - Conversation list menu

/// Right-click menu for a conversation row, drawn like the message menu so it can zoom in.
struct ThreadActionMenu: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.supports("pin_thread") {
                row(thread.pinned ? "Bỏ ghim" : "Ghim cuộc trò chuyện", thread.pinned ? "pin.slash" : "pin") {
                    store.threadCommand("pin_thread", thread: thread, parameters: ["pin": .bool(!thread.pinned)])
                }
            }
            if store.supports("mute_thread") {
                row(thread.muted ? "Bật thông báo" : "Tắt thông báo", thread.muted ? "bell" : "bell.slash") {
                    store.threadCommand("mute_thread", thread: thread, parameters: ["mute": .bool(!thread.muted)])
                }
            }
            row("Tải lại tin nhắn", "arrow.clockwise") { store.loadMessages(thread) }
            if store.supports("set_thread_priority") {
                let priority = store.isPriority(thread)
                row(priority ? "Chuyển sang mục Khác" : "Đưa vào Ưu tiên", priority ? "tray" : "star") {
                    store.featureThread("set_thread_priority", thread: thread, values: ["priority": .bool(!priority)])
                }
            }
            if !thread.isGroup && store.supports("update_alias") { row("Đặt tên gợi nhớ…", "pencil") { store.aliasThread = thread } }
            if store.supports("set_thread_category") { row("Phân loại…", "tag") { store.threadOptions = thread } }
            if store.supports("mark_thread_unread") {
                row(thread.hasUnread ? "Đánh dấu đã đọc" : "Đánh dấu chưa đọc", thread.hasUnread ? "envelope.open" : "envelope.badge") {
                    store.featureThread("mark_thread_unread", thread: thread, values: ["unread": .bool(!thread.hasUnread)])
                }
            }
            if !thread.isGroup {
                if store.supports("add_group_members") { row("Thêm vào nhóm…", "person.crop.circle.badge.plus") { store.addToGroupUser = store.contactRow(for: thread) } }
                if store.supports("create_group") { row("Tạo nhóm với người này…", "person.3") { store.groupSeed = store.contactRow(for: thread) } }
            } else if store.supports("add_group_members") { row("Thêm thành viên…", "person.badge.plus") { store.groupToInvite = thread } }
            if store.supports("upsert_reminder") { row("Tạo nhắc hẹn…", "bell.badge") { store.reminderThread = thread } }
            if store.supports("hide_thread") { row("Ẩn hội thoại", "eye.slash") { store.featureThread("hide_thread", thread: thread, values: ["hide": .bool(true)]) } }
            if store.supports("delete_thread") {
                Divider().padding(.vertical, 4).padding(.horizontal, 10)
                row("Xóa hội thoại…", "trash", destructive: true) { store.destructiveThread = thread }
            }
        }
        .font(.system(size: 13))
        .padding(6).frame(width: 248)
        .modifier(MenuSurface(radius: 18))
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button { run(); close() } label: {
            Label(title, systemImage: icon).foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}
