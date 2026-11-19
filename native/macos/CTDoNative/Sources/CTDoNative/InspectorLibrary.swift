import SwiftUI
import AppKit
import NativeBridge

/// Photos, files, links, server pins and members of the open conversation.
struct InspectorLibrary: View {
    @EnvironmentObject var store: AppStore
    let thread: ThreadSnapshot
    @State private var tab: String
    init(thread: ThreadSnapshot, initialTab: String = "photos") { self.thread=thread; _tab=State(initialValue:initialTab) }
    @State private var expanded = false
    /// The member whose profile card is open from the member list.
    @State private var profileMemberID: String?
    private let grid = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    private var photos: [MessageSnapshot] { store.selectedMessages.filter { $0.imageURL != nil && $0.fileURL == nil }.reversed() }
    private var files: [MessageSnapshot] { store.selectedMessages.filter { $0.fileURL != nil }.reversed() }
    private var links: [MessageSnapshot] { store.selectedMessages.filter { $0.linkURL != nil && $0.imageURL == nil && $0.fileURL == nil }.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Thư viện", selection: $tab) {
                Text("Ảnh").tag("photos"); Text("Tệp").tag("files"); Text("Liên kết").tag("links"); Text("Ghim").tag("pins")
                if thread.isGroup { Text("Thành viên").tag("members") }
            }
            .pickerStyle(.segmented).labelsHidden()
            content
            Text("Từ \(store.selectedMessages.count) tin đã tải trong cuộc trò chuyện").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .onValueChange(of: tab) { _, value in
            expanded = false
            if value == "members", store.supports("get_group_members") { store.threadCommand("get_group_members", thread: thread) }
            if value == "pins", store.supports("list_pinned_topics") { store.threadCommand("list_pinned_topics", thread: thread) }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case "photos":
            if photos.isEmpty { empty("Chưa có ảnh", "photo") } else {
                LazyVGrid(columns: grid, spacing: 4) {
                    ForEach(limited(photos, 9)) { message in
                        if let url = MediaSource.photo(message) {
                            Button { store.jump(toThread: thread.id, messageID: message.id) } label: {
                                Color.primary.opacity(0.06).aspectRatio(1, contentMode: .fit)
                                    .overlay { AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.mini) } }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).help("Đến tin gốc")
                            .contextMenu { mediaMenu(message, url: url) }
                        }
                    }
                }
                more(photos.count, 9)
            }
        case "files":
            if files.isEmpty { empty("Chưa có tệp", "doc") } else {
                ForEach(limited(files, 5)) { message in
                    row(icon: "doc.fill", title: message.fileName ?? "Tệp đính kèm", detail: message.date.formatted(date: .abbreviated, time: .omitted)) {
                        if let url = safeWebURL(message.fileURL) { NSWorkspace.shared.open(url) }
                    }
                    .contextMenu { mediaMenu(message, url: safeWebURL(message.fileURL)) }
                }
                more(files.count, 5)
            }
        case "links":
            if links.isEmpty { empty("Chưa có liên kết", "link") } else {
                ForEach(limited(links, 5)) { message in
                    let url = safeWebURL(message.linkURL)
                    row(icon: "link", title: message.linkTitle ?? url?.host ?? "Liên kết", detail: url?.host ?? "") {
                        if let url { NSWorkspace.shared.open(url) }
                    }
                    .contextMenu {
                        Button("Đến tin gốc") { store.jump(toThread: thread.id, messageID: message.id) }
                        if let url { Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } }
                    }
                }
                more(links.count, 5)
            }
        case "pins":
            let pins = store.features.pinnedTopics[thread.id] ?? []
            if pins.isEmpty {
                empty(store.busy.contains("list_pinned_topics") ? "Đang tải…" : "Chưa có tin ghim trên nhóm", "pin")
            } else {
                ForEach(pins) { row in
                    Label { Text(verbatim: row.string("text", "title", "content")).lineLimit(3).textSelection(.enabled) } icon: { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                        .font(.callout)
                }
            }
        default:
            let members = store.features.members[thread.id] ?? []
            if members.isEmpty {
                empty(store.busy.contains("get_group_members") ? "Đang tải…" : "Chưa tải được thành viên", "person.2")
            } else {
                ForEach(limited(members, 8)) { row in
                    HStack(spacing: 9) {
                        let role = Int(row.number("role"))
                        // Avatar and name open the member's profile card, like a tag or avatar in the chat.
                        Button { profileMemberID = row.id } label: {
                        HStack(spacing: 9) {
                        AvatarView(name: row.string("name", "display_name"), url: row.string("avatar"), size: 26)
                            .overlay(alignment: .bottomTrailing) {
                                if role > 0 {
                                    // Zalo marks the owner and deputies with a key on the avatar.
                                    Image(systemName: "key.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 13, height: 13)
                                        .background(role == 2 ? Color.orange : Color.gray, in: Circle())
                                        .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5) }
                                        .offset(x: 3, y: 3)
                                }
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: store.aliases[row.id] ?? row.string("name", "display_name", "user_id")).lineLimit(1)
                            if role > 0 {
                                Text(role == 2 ? "Trưởng nhóm" : "Phó nhóm").font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(role == 2 ? Color.orange : .secondary)
                            }
                        }
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Xem thông tin \(row.string("name", "display_name"))")
                        .windowBoundedPopover(isPresented: Binding(get: { profileMemberID == row.id }, set: { if !$0 { profileMemberID = nil } })) {
                            ContactProfilePopover(userID: row.id, name: row.string("name", "display_name"),
                                                  avatar: row.string("avatar").isEmpty ? nil : row.string("avatar")) { profileMemberID = nil }
                        }
                        Spacer()
                        if row.id != store.session.uin {
                            Button { store.openDirect(userID: row.id, name: row.string("name", "display_name"), avatar: row.string("avatar")) } label: {
                                Label("Nhắn tin", systemImage: "bubble.left.fill").font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule()).foregroundStyle(Color.accentColor)
                            }.buttonStyle(.plain).help("Mở cuộc trò chuyện với \(row.string("name", "display_name"))")
                        }
                    }
                }
                more(members.count, 8)
            }
            if store.supports("add_group_members") {
                Button { store.groupToInvite = thread } label: { Label("Thêm thành viên", systemImage: "person.badge.plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func limited<T>(_ items: [T], _ count: Int) -> [T] { expanded ? items : Array(items.prefix(count)) }

    @ViewBuilder private func more(_ total: Int, _ shown: Int) -> some View {
        if total > shown {
            Button(expanded ? "Thu gọn" : "Xem tất cả (\(total))") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                .buttonStyle(.plain).font(.callout).foregroundStyle(Color.accentColor)
        }
    }

    private func empty(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 14)
    }

    private func row(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).lineLimit(1)
                    if !detail.isEmpty { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func mediaMenu(_ message: MessageSnapshot, url: URL?) -> some View {
        Button("Đến tin gốc") { store.jump(toThread: thread.id, messageID: message.id) }
        if let url { Button("Mở") { NSWorkspace.shared.open(url) } }
        if store.supports("download_media") { Button("Lưu về máy…") { store.downloadMedia(message) } }
    }
}
