import AppKit
import SwiftUI
import NativeBridge

// MARK: - Animated images (stickers)

/// Shared decoded images; animated WebP and GIF keep every frame inside the `NSImage`.
@MainActor
enum AnimatedImageCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>(); cache.countLimit = 300; return cache
    }()
    private static var loading: [URL: Task<NSImage?, Never>] = [:]

    static func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = loading[url] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, data.count < 4_000_000 else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// `NSImageView` plays animated WebP/GIF frames, which SwiftUI `Image` does not.
struct AnimatedRemoteImage: NSViewRepresentable {
    let url: URL
    var animates = true
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = animates
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        view.animates = animates
        if context.coordinator.url != url { load(into: view, coordinator: context.coordinator) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL? }
    private func load(into view: NSImageView, coordinator: Coordinator) {
        coordinator.url = url
        let target = url
        Task { @MainActor in
            let image = await AnimatedImageCache.image(for: target)
            guard coordinator.url == target else { return }
            view.image = image
        }
    }
}

/// A sticker sits on the transcript at Zalo's own 130-point size and keeps playing.
struct StickerBubble: View {
    let url: URL
    var size: CGFloat = 120
    var body: some View {
        AnimatedRemoteImage(url: url).frame(width: size, height: size)
            .accessibilityLabel("Nhãn dán")
    }
}

// MARK: - Sticker picker

struct StickerPopover: View {
    @EnvironmentObject private var store: AppStore
    let close: () -> Void
    @State private var query = ""
    @State private var pack: UInt64?
    @State private var hovered: UInt64?
    @AppStorage("nativeRecentStickers") private var recentStorage = ""
    private let columns = Array(repeating: GridItem(.fixed(78), spacing: 6), count: 5)

    /// Recent stickers are stored as `id:category:type` triples.
    private var recent: [StickerItem] {
        recentStorage.split(separator: " ").compactMap { token in
            let parts = token.split(separator: ":").compactMap { UInt64($0) }
            guard parts.count == 3 else { return nil }
            return try? JSONDecoder().decode(StickerItem.self, from: Data("""
            {"sticker_id":\(parts[0]),"cate_id":\(parts[1]),"sticker_type":\(parts[2]),"image_url":"https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=\(parts[0])&size=130"}
            """.utf8))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm nhãn dán", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(12)
            ScrollView {
                if pack == nil && query.isEmpty {
                    if recent.isEmpty {
                        EmptyState("Chưa dùng nhãn dán nào", systemImage: "clock", description: Text("Chọn một bộ nhãn dán bên dưới."))
                            .padding(.top, 40)
                    } else { grid(recent) }
                } else if store.stickerItems.isEmpty {
                    Group {
                        if !store.busy.isDisjoint(with: ["sticker_pack", "search_stickers"]) { ProgressView() }
                        else { Text(query.isEmpty ? "Bộ nhãn dán trống" : "Không tìm thấy nhãn dán").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).padding(.top, 60)
                } else { grid(store.stickerItems) }
            }
            .frame(maxHeight: .infinity)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tab(selected: pack == nil && query.isEmpty, help: "Dùng gần đây") {
                        Image(systemName: "clock").font(.system(size: 15)).foregroundStyle(.secondary)
                    } action: { query = ""; pack = nil }
                    ForEach(store.stickerPacks) { item in
                        tab(selected: pack == item.id, help: item.name) {
                            if let url = safeWebURL(item.iconURL) { AnimatedRemoteImage(url: url, animates: false) }
                            else { Text(String(item.name.prefix(1))).font(.caption.weight(.semibold)) }
                        } action: { query = ""; pack = item.id; store.send("sticker_pack", parameters: ["cate_id": .number(Double(item.id))]) }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .frame(width: 444, height: 420)
        .onAppear { if store.stickerPacks.isEmpty { store.send("sticker_packs") } }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty, store.supports("search_stickers") else { return }
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            pack = nil
            store.send("search_stickers", parameters: ["keyword": .string(query)])
        }
    }

    private func grid(_ items: [StickerItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(items) { sticker in
                Button { send(sticker) } label: {
                    Group {
                        if let url = safeWebURL(sticker.imageURL) {
                            // Only the hovered cell animates, keeping a full grid cheap to draw.
                            if let sprite = safeWebURL(sticker.spriteURL), let frames = sticker.totalFrames, frames > 1 {
                                SpriteSticker(spriteURL: sprite, frames: frames, duration: Double(frames) * Double(sticker.durationMs ?? 250) / 1000,
                                              size: 70, playing: hovered == sticker.id)
                            } else { AnimatedRemoteImage(url: url, animates: false) }
                        } else { Image(systemName: "face.smiling").font(.largeTitle) }
                    }
                    .frame(width: 70, height: 70).padding(4)
                    .background(hovered == sticker.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(!store.canSend)
                .onHover { if $0 { hovered = sticker.id } else if hovered == sticker.id { hovered = nil } }
                .help(sticker.label ?? "Gửi nhãn dán")
            }
        }.padding(10)
    }

    private func tab<Label: View>(selected: Bool, help: String, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label().frame(width: 30, height: 30).padding(3)
                .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(help)
    }

    private func send(_ sticker: StickerItem) {
        store.sendSticker(sticker)
        let token = "\(sticker.stickerID):\(sticker.categoryID):\(sticker.stickerType)"
        var items = recentStorage.split(separator: " ").map(String.init).filter { $0 != token }
        items.insert(token, at: 0)
        recentStorage = items.prefix(20).joined(separator: " ")
        close()
    }
}

// MARK: - Message actions (right click)

/// Right-click target: the message under the pointer and where the menu opens, in view coordinates.
struct MessageMenuTarget: Equatable {
    let message: MessageSnapshot
    let point: CGPoint
}

/// Opens the message menu on a right click over a hovered message, instead of the system menu.
@MainActor
final class MessageMenuMonitor: ObservableObject {
    private var monitor: Any?
    func install(hovered: @escaping () -> String?, open: @escaping (String, NSPoint) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            nonisolated(unsafe) let captured = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let id = hovered(), captured.window?.isKeyWindow ?? true else { return false }
                open(id, captured.locationInWindow)
                return true
            }
            return consumed ? nil : event
        }
    }
    func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

struct MessageActionMenu: View {
    @EnvironmentObject private var store: AppStore
    let message: MessageSnapshot
    let thread: ThreadSnapshot
    let close: () -> Void
    let recall: () -> Void
    @State private var showingForward = false
    @State private var showingAllReactions = false
    private let reactions = ["❤️", "👍", "😆", "😮", "😢", "😡"]

    private var pinned: Bool {
        store.features.rows("pinned_messages").contains { $0.string("thread_id") == thread.id && $0.string("message_id") == message.id }
    }
    private var forwardTargets: [ThreadSnapshot] {
        Array(store.threads.filter { !$0.hidden && $0.id != thread.id }
            .sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }.prefix(8))
    }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 8) {
            if store.supports("react") {
                HStack(spacing: 2) {
                    ForEach(reactions, id: \.self) { emoji in
                        Button { store.messageAction("react", message: message, reaction: emoji); close() } label: {
                            Text(emoji).font(.system(size: 26)).frame(width: 40, height: 40).contentShape(Circle())
                        }.buttonStyle(ReactionButtonStyle())
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .modifier(MenuSurface(radius: 26))
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if store.supports("send_quote") { row("Trả lời", "arrowshape.turn.up.left") { store.quote = message } }
                    if !message.text.isEmpty {
                        row("Sao chép", "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(MessageTypography.inline(message.text).characters), forType: .string)
                        }
                    }
                    if message.imageURL != nil && message.messageType != "chat.sticker" && store.supports("download_media") {
                        row("Sao chép ảnh", "photo") { store.downloadMedia(message, copyImage: true) }
                    }
                    if store.supports("pin_message_local") {
                        row(pinned ? "Bỏ ghim" : "Ghim", pinned ? "pin.slash" : "pin") {
                            store.featureThread("pin_message_local", thread: thread, values: ["message_id": .string(message.id), "pinned": .bool(!pinned)])
                        }
                    }
                    if store.supports("forward_message") {
                        Button { showingForward.toggle() } label: {
                            HStack { Label("Chuyển tiếp", systemImage: "arrowshape.turn.up.right"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(showingForward ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle())
                    }
                    row("Chọn", "checkmark.circle") { store.selectingMessages = true; store.selectedMessageIDs.insert(message.id) }
                    if store.supports("bookmark_message") {
                        let marked = store.isBookmarked(message, thread: thread)
                        row(marked ? "Bỏ đánh dấu" : "Đánh dấu", marked ? "star.slash" : "star") { store.setBookmark(message, thread: thread, marked: !marked) }
                    }
                    if (message.imageURL != nil && message.messageType != "chat.sticker") || message.fileURL != nil, store.supports("download_media") {
                        row("Lưu về máy", "arrow.down.circle") { store.downloadMedia(message) }
                    }
                    row("Xem chi tiết", "info.circle") { store.messageDetails = message }
                    if (store.supports("recall_message") && message.isOutgoing) || store.supports("delete_message") {
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                    }
                    if store.supports("recall_message") && message.isOutgoing { row("Thu hồi", "arrow.uturn.backward", destructive: true, run: recall) }
                    if store.supports("delete_message") {
                        row("Xóa ở phía tôi", "trash", destructive: true) { store.messageAction("delete_message", message: message) }
                    }
                }
                .padding(6).frame(width: 236)
                .modifier(MenuSurface(radius: 18))
                if showingForward {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(forwardTargets) { target in
                            Button { store.forwardNow(message, to: target); close() } label: {
                                HStack(spacing: 9) {
                                    ThreadAvatar(thread: target, size: 24)
                                    Text(verbatim: target.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(MenuRowStyle())
                        }
                        Divider().padding(.vertical, 4).padding(.horizontal, 10)
                        row("Khác…", "ellipsis.circle") { store.openForward(message) }
                    }
                    .padding(6).frame(width: 240)
                    .modifier(MenuSurface(radius: 18))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .font(.system(size: 13))
        .animation(.snappy(duration: 0.18), value: showingForward)
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button { run(); close() } label: {
            Label(title, systemImage: icon).foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

/// Opaque enough to read over any wallpaper, while keeping the glass edge.
struct MenuSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .nativeGlass(radius)
            .background(Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.9 : 0.93), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MenuRowBody(configuration: configuration) }
    private struct MenuRowBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover || configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .onHover { hover = $0 }
        }
    }
}

private struct ReactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ReactionBody(configuration: configuration) }
    private struct ReactionBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label.scaleEffect(configuration.isPressed ? 0.85 : hover ? 1.22 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// Full emoji set for reactions, reusing the composer picker's catalogue.
private struct ReactionPicker: View {
    let pick: (String) -> Void
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 2), count: 9)
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(EmojiCatalog.categories.prefix(2).flatMap(\.emoji) + EmojiCatalog.categories[7].emoji, id: \.self) { emoji in
                    Button { pick(emoji) } label: { Text(emoji).font(.system(size: 22)).frame(width: 34, height: 34) }.buttonStyle(.plain)
                }
            }.padding(8)
        }.frame(width: 340, height: 300)
    }
}

// MARK: - Sidebar search

/// Zalo-style results inside the sidebar card: phone lookup, conversations, messages and files.
struct SidebarSearchResults: View {
    @EnvironmentObject private var store: AppStore
    let query: String
    @ObservedObject var recentSearches: RecentSearchHistory
    let selectRecent: (String) -> Void
    let close: () -> Void
    @State private var showAllContacts = false
    @State private var showAllMessages = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var phone: String? {
        let digits = trimmed.filter(\.isNumber)
        guard digits.count == trimmed.filter({ !$0.isWhitespace && $0 != "+" && $0 != "." && $0 != "-" }).count else { return nil }
        // Only a whole number: 0xxxxxxxxx, or 84 followed by nine digits; partial input looks nothing up.
        let whole = (digits.count == 10 && digits.hasPrefix("0")) || (digits.count == 11 && digits.hasPrefix("84"))
        return whole ? digits : nil
    }
    private var conversations: [ThreadSnapshot] {
        store.threads.filter { (!$0.hidden || store.hiddenUnlocked) && $0.name.localizedStandardContains(trimmed) }
            .sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }
    }
    private var messages: [HistoryHit] { store.historyResults.filter { $0.message.fileName == nil } }
    private var files: [HistoryHit] { store.historyResults.filter { $0.message.fileName != nil } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                if trimmed.isEmpty {
                    if recentSearches.queries.isEmpty {
                        EmptyState("Chưa có tìm kiếm gần đây", systemImage: "clock.arrow.circlepath",
                                               description: Text("Nhập tên, số điện thoại hoặc nội dung tin nhắn."))
                            .padding(.top, 40)
                    } else {
                        HStack {
                            Text("Tìm kiếm gần đây").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Xóa tất cả") { recentSearches.clear() }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                        ForEach(recentSearches.queries, id: \.self) { query in
                            HStack(spacing: 8) {
                                Button { selectRecent(query) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                        Text(verbatim: query).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { recentSearches.remove(query) } label: { Image(systemName: "xmark").font(.caption).padding(6) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Xóa khỏi tìm kiếm gần đây")
                            }.padding(.horizontal, 12)
                        }
                    }
                } else {
                    if let phone, store.supports("lookup_phone") { phoneCard(phone) }
                    if !conversations.isEmpty {
                        header("Liên hệ và nhóm", count: conversations.count)
                        ForEach(showAllContacts ? conversations : Array(conversations.prefix(5))) { thread in
                            resultRow { ThreadAvatar(thread: thread, size: 40) } title: {
                                Text(highlighted(thread.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            } detail: {
                                Text(thread.isGroup ? "Nhóm" : "Cá nhân").font(.caption).foregroundStyle(.secondary)
                            } action: { store.selectThread(thread.id); close() }
                        }
                        if conversations.count > 5 { more($showAllContacts) }
                    }
                    if store.supports("search_history") {
                        header("Tin nhắn", count: messages.count)
                        if store.busy.contains("search_history") && messages.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(10) }
                        ForEach(showAllMessages ? messages : Array(messages.prefix(8))) { hit in
                            let owner = store.threads.first { $0.id == hit.threadID }
                            resultRow {
                                if let owner { ThreadAvatar(thread: owner, size: 40) } else { AvatarView(name: hit.message.senderName, size: 40) }
                            } title: {
                                HStack {
                                    Text(verbatim: owner?.name ?? "Hội thoại đã lưu").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(hit.message.date, format: .dateTime.day().month(.twoDigits).year(.twoDigits)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            } detail: {
                                Text((hit.message.isOutgoing ? AttributedString("Bạn: ") : AttributedString()) + highlighted(hit.message.text))
                                    .font(.system(size: 13)).lineLimit(2)
                            } action: { store.jump(toThread: hit.threadID, messageID: hit.message.id); close() }
                        }
                        if messages.count > 8 { more($showAllMessages) }
                        if !store.busy.contains("search_history") && messages.isEmpty {
                            Text("Không có tin nhắn phù hợp trong lịch sử đã lưu.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                        }
                        if !files.isEmpty {
                            header("Tệp", count: files.count)
                            ForEach(files.prefix(8)) { hit in
                                resultRow {
                                    Image(systemName: "doc.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                                        .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                } title: {
                                    Text(highlighted(hit.message.fileName ?? "Tệp")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                } detail: {
                                    Text(verbatim: store.threads.first { $0.id == hit.threadID }?.name ?? "").font(.caption).foregroundStyle(.secondary)
                                } action: { store.jump(toThread: hit.threadID, messageID: hit.message.id); close() }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 10)
        }
        .task(id: trimmed) {
            store.historyResults = []
            guard !trimmed.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 260_000_000) } catch { return }
            store.searchHistory(trimmed, onlyCurrentThread: false)
            if let phone, store.supports("lookup_phone") {
                store.contactResult = nil
                // Shown in the panel itself ("Không tìm thấy…"), never as a banner.
                if let id = store.send("lookup_phone", parameters: ["phone": .string(phone)]) { store.quietRequests.insert(id) }
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        if let range = value.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            value[range].foregroundColor = .accentColor
            value[range].font = .system(size: 13, weight: .semibold)
        }
        return value
    }

    private func header(_ title: String, count: Int) -> some View {
        Text(count > 0 ? "\(title) (\(count))" : title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
    }

    private func more(_ flag: Binding<Bool>) -> some View {
        Button(flag.wrappedValue ? "Thu gọn" : "Xem tất cả") { flag.wrappedValue.toggle() }
            .buttonStyle(.plain).font(.callout).foregroundStyle(Color.accentColor).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func resultRow<Icon: View, Title: View, Detail: View>(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title,
                                                                 @ViewBuilder detail: () -> Detail, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 2) { title(); detail() }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }

    @ViewBuilder private func phoneCard(_ phone: String) -> some View {
        header("Tìm bạn qua số điện thoại", count: 0)
        HStack(spacing: 12) {
            if let result = store.contactResult, let uid = result["user_id"]?.string {
                let name = result["display_name"]?.string ?? "Người dùng Zalo"
                AvatarView(name: name, url: result["avatar"]?.string, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name).font(.system(size: 14, weight: .semibold))
                    Text("Số điện thoại: \(phone)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.threads.contains { $0.id == uid } ? "Nhắn tin" : "Mở") {
                    if store.threads.contains(where: { $0.id == uid }) { store.selectThread(uid) }
                    else { store.send("open_contact", parameters: ["user_id": .string(uid), "name": .string(name), "avatar": .string(result["avatar"]?.string ?? "")]) }
                    close()
                }.buttonStyle(.borderedProminent).controlSize(.small)
            } else if store.busy.contains("lookup_phone") {
                ProgressView().controlSize(.small); Text("Đang tìm số \(phone)…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.title2).foregroundStyle(.secondary)
                Text("Không tìm thấy tài khoản Zalo cho số này.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 4)
    }
}

// MARK: - Conversation info card

/// Details beside the transcript in a floating card, laid out as Zalo's conversation panel.
struct ConversationInfoPanel: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    @State private var showingProfile = false
    @State private var photosOpen = true
    @State private var filesOpen = true
    @State private var linksOpen = false
    @State private var showAllPhotos = false
    @State private var showAllFiles = false
    @State private var showAllLinks = false
    private var loadingLibrary: Bool { store.threadLibraries[thread.id] == nil && store.busy.contains("thread_library") }
    private var alias: String { store.features.thread(thread.id)?.string("alias") ?? "" }
    /// The whole local history when the library has loaded, plus anything newer in the open transcript.
    private var source: [MessageSnapshot] {
        var seen = Set<String>()
        let merged = (store.selectedMessages + (store.threadLibraries[thread.id]?.all ?? [])).filter { seen.insert($0.id).inserted }
        return merged.sorted { $0.timestamp > $1.timestamp }
    }
    private var photos: [MessageSnapshot] {
        source.filter { $0.imageURL != nil && $0.fileURL == nil && $0.messageType != "chat.sticker" && MediaPresentation.fileURL($0) == nil }
    }
    /// Files include links to Zalo's file CDN, which older clients and backups store as plain links.
    private var files: [MessageSnapshot] { source.filter { $0.messageType != "chat.sticker" && MediaPresentation.fileURL($0) != nil && ($0.imageURL == nil || $0.fileURL != nil) } }
    private var links: [MessageSnapshot] { source.filter { MediaPresentation.showsLinkPreview($0) && LocationPoint($0) == nil } }
    private var historyCount: Int { max(store.threadLibraries[thread.id]?.scanned ?? 0, store.selectedMessages.count) }
    private let grid = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thông tin hội thoại").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.showingInspector = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.07), in: Circle()).keyboardShortcut(.cancelAction).help("Đóng (Esc)")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        ThreadAvatar(thread: thread, size: 76)
                        HStack(spacing: 6) {
                            Text(verbatim: thread.name).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                            if store.supports("update_alias") && !thread.isGroup {
                                Button { store.aliasThread = thread } label: { Image(systemName: "pencil").font(.system(size: 12)) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Đổi tên gợi nhớ")
                            }
                        }
                        if let zaloName = store.originalNames[thread.id], zaloName != thread.name { Text("Tên Zalo: \(zaloName)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: 4), spacing: 10) {
                        if store.supports("mute_thread") {
                            circleAction(thread.muted ? "bell" : "bell.slash", thread.muted ? "Bật thông báo" : "Tắt thông báo") {
                                store.threadCommand("mute_thread", thread: thread, parameters: ["mute": .bool(!thread.muted)])
                            }
                        }
                        if store.supports("pin_thread") {
                            circleAction(thread.pinned ? "pin.slash" : "pin", thread.pinned ? "Bỏ ghim" : "Ghim hội thoại") {
                                store.threadCommand("pin_thread", thread: thread, parameters: ["pin": .bool(!thread.pinned)])
                            }
                        }
                        if thread.isGroup {
                            if store.supports("add_group_members") { circleAction("person.badge.plus", "Thêm thành viên") { store.groupToInvite = thread } }
                        } else if store.supports("create_group") {
                            circleAction("person.2.badge.plus", "Tạo nhóm trò chuyện") { store.groupSeed = store.contactRow(for: thread) }
                        }
                        if store.supports("start_call") { circleAction("phone", "Gọi thoại") { store.startCall(video: false) } }
                        if store.supports("start_call") { circleAction("video", "Gọi video") { store.startCall(video: true) } }
                        circleAction("magnifyingglass", "Tìm tin nhắn") { store.showingConversationSearch = true }
                    }
                    card {
                        if !thread.isGroup {
                            listRow("person.crop.circle", "Thông tin tài khoản") { showingProfile = true }
                                .windowBoundedPopover(isPresented: $showingProfile) {
                                    ContactProfileCard(userID: thread.id, fallbackName: thread.name, fallbackAvatar: thread.avatar) { showingProfile = false }
                                }
                            Divider().padding(.leading, 42)
                        }
                        listRow("alarm", "Danh sách nhắc hẹn") { store.workspaceSection = .saved; store.reloadWorkspaceFeatures() }
                        if store.supports("upsert_reminder") { Divider().padding(.leading, 42); listRow("bell.badge", "Tạo nhắc hẹn") { store.reminderThread = thread } }
                        if store.supports("set_thread_category") { Divider().padding(.leading, 42); listRow("tag", "Phân loại hội thoại") { store.threadOptions = thread } }
                    }
                    if thread.isGroup {
                        card { InspectorLibrary(thread: thread, initialTab: "members").padding(.vertical, 8) }
                    }
                    section("Ảnh/Video", open: $photosOpen) {
                        if photos.isEmpty { emptyLine(loadingLibrary ? "Đang tìm trong lịch sử…" : "Chưa có ảnh hoặc video") } else {
                            LazyVGrid(columns: grid, spacing: 5) {
                                ForEach(showAllPhotos ? photos : Array(photos.prefix(8))) { message in
                                    if let url = MediaSource.photo(message) {
                                        Button { store.jump(toThread: thread.id, messageID: message.id) } label: {
                                            Color.primary.opacity(0.06).aspectRatio(1, contentMode: .fit)
                                                .overlay { DownsampledPhoto(url: url) }
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain).help("Đến tin gốc")
                                    }
                                }
                            }
                            if photos.count > 8 { wideButton(showAllPhotos ? "Thu gọn" : "Xem tất cả") { showAllPhotos.toggle() } }
                        }
                    }
                    section("File", open: $filesOpen) {
                        if files.isEmpty { emptyLine(loadingLibrary ? "Đang tìm trong lịch sử…" : "Chưa có tệp") } else {
                            ForEach(showAllFiles ? Array(files.prefix(100)) : Array(files.prefix(6))) { message in
                                let name = MediaPresentation.fileName(message) ?? safeWebURL(MediaPresentation.fileURL(message))?.lastPathComponent ?? "Tệp đính kèm"
                                Button { if let url = safeWebURL(MediaPresentation.fileURL(message)) { NSWorkspace.shared.open(url) } } label: {
                                    HStack(spacing: 10) {
                                        FileBadge(name: name)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                            Text(message.date, format: .dateTime.day().month(.twoDigits).year()).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Đến tin gốc") { store.jump(toThread: thread.id, messageID: message.id) }
                                    if store.supports("download_media") { Button("Lưu về máy…") { store.downloadMedia(message) } }
                                }
                            }
                            if files.count > 6 { wideButton(showAllFiles ? "Thu gọn" : "Xem tất cả (\(files.count))") { showAllFiles.toggle() } }
                        }
                    }
                    section("Link", open: $linksOpen) {
                        if links.isEmpty { emptyLine(loadingLibrary ? "Đang tìm trong lịch sử…" : "Chưa có liên kết") } else {
                            ForEach(showAllLinks ? Array(links.prefix(100)) : Array(links.prefix(6))) { message in
                                if let url = safeWebURL(message.linkURL) {
                                    Link(destination: url) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "link").frame(width: 34, height: 34).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(verbatim: message.linkTitle ?? url.host ?? "Liên kết").font(.system(size: 13, weight: .medium)).lineLimit(1)
                                                Text(verbatim: url.host ?? "").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                    }.buttonStyle(.plain)
                                    .contextMenu { Button("Đến tin gốc") { store.jump(toThread: thread.id, messageID: message.id) } }
                                }
                            }
                            if links.count > 6 { wideButton(showAllLinks ? "Thu gọn" : "Xem tất cả (\(links.count))") { showAllLinks.toggle() } }
                        }
                    }
                    card {
                        if store.supports("sync_history") { listRow("arrow.triangle.2.circlepath", "Đồng bộ lịch sử") { store.threadCommand("sync_history", thread: thread) } }
                        if store.supports("hide_thread") {
                            Divider().padding(.leading, 42)
                            listRow("eye.slash", "Ẩn trò chuyện") { store.featureThread("hide_thread", thread: thread, values: ["hide": .bool(true)]) }
                        }
                        if store.supports("delete_thread") { Divider().padding(.leading, 42); listRow("trash", "Xóa lịch sử trò chuyện", destructive: true) { store.destructiveThread = thread } }
                        if !thread.isGroup && store.supports("set_contact_blocked") {
                            Divider().padding(.leading, 42)
                            listRow("hand.raised", "Chặn liên hệ", destructive: true) { store.blockCandidate = store.contactRow(for: thread) }
                        }
                    }
                    Text("Ảnh, tệp và liên kết từ \(historyCount) tin đã lưu trên máy.").font(.caption2).foregroundStyle(.tertiary)
                }.padding(14)
            }
        }
        .onAppear {
            if thread.isGroup, store.features.members[thread.id] == nil, store.supports("get_group_members") { store.threadCommand("get_group_members", thread: thread) }
            store.requestThreadLibrary(thread)
        }
        // New media in the open conversation refreshes the library while the card is visible.
        .onValueChange(of: store.selectedMessages.last?.id) { _, _ in store.requestThreadLibrary(thread) }
    }

    private func circleAction(_ icon: String, _ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.07), in: Circle())
                Text(title).font(.system(size: 10.5)).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func section<Content: View>(_ title: String, open: Binding<Bool>, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.wrappedValue.toggle() } } label: {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open.wrappedValue ? 0 : -90))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open.wrappedValue { content() }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func listRow(_ icon: String, _ title: String, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(destructive ? Color.red : Color.secondary)
                Text(title).foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
            }.font(.system(size: 13)).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func wideButton(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Coloured document badge by extension, as file rows show on Zalo.
struct FileBadge: View {
    let name: String
    private var kind: (String, Color) {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return ("PDF", .red)
        case "doc", "docx": return ("W", .blue)
        case "xls", "xlsx", "csv": return ("X", .green)
        case "ppt", "pptx": return ("P", .orange)
        case "zip", "rar", "7z": return ("ZIP", .purple)
        case "mp4", "mov": return ("VID", .pink)
        default: return ("FILE", .gray)
        }
    }
    var body: some View {
        Text(kind.0).font(.system(size: kind.0.count > 2 ? 9 : 14, weight: .bold)).foregroundStyle(.white)
            .frame(width: 34, height: 40)
            .background(kind.1.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

@MainActor
extension AppStore {
    /// Forwards one message straight to a chosen conversation, as the quick forward list does.
    func forwardNow(_ message: MessageSnapshot, to target: ThreadSnapshot) {
        forwardQueue = [message]; forwardMessage = message; forwardSourceThread = selectedThread
        forward(to: target)
    }

    /// Name and avatar shown beside a received message: the local alias first, then the group member profile.
    func senderIdentity(_ message: MessageSnapshot, in thread: ThreadSnapshot) -> (name: String, avatar: String?, id: String) {
        guard thread.isGroup else {
            return (thread.name, thread.avatar, thread.id)
        }
        let members = features.members[thread.id] ?? []
        // History restored from a backup has no sender ID; the display name is then the only link.
        let member = members.first { !message.senderID.isEmpty && $0.id == message.senderID }
            ?? members.first { !message.senderName.isEmpty && $0.string("name", "display_name") == message.senderName }
        let id = member?.id ?? message.senderID
        let alias = id.isEmpty ? "" : aliases[id] ?? features.thread(id)?.string("alias") ?? ""
        let memberName = member?.string("name", "display_name") ?? ""
        let name = !alias.isEmpty ? alias : !memberName.isEmpty ? memberName : message.senderName
        let avatar = member.map { $0.string("avatar") }.flatMap { $0.isEmpty ? nil : $0 }
            ?? threads.first { !id.isEmpty && $0.id == id }?.avatar
        return (name, avatar, id)
    }

    /// Opens the one-to-one conversation with a person, creating it from their profile when needed.
    func openDirect(userID: String, name: String, avatar: String?) {
        guard !userID.isEmpty else { error = "Chưa xác định được tài khoản của người này."; return }
        showingInspector = false; workspaceSection = .messages
        if threads.contains(where: { $0.id == userID && !$0.isGroup }) { selectThread(userID); return }
        guard supports("open_contact") else { error = "Chưa mở được cuộc trò chuyện với người này."; return }
        send("open_contact", parameters: ["user_id": .string(userID), "name": .string(name), "avatar": .string(avatar ?? "")])
    }
}

// MARK: - Sticker animation

@MainActor
extension AppStore {
    func rememberStickerArt(_ items: [StickerItem]) {
        for item in items where item.spriteURL != nil && (item.totalFrames ?? 0) > 1 { stickerArt[item.stickerID] = item }
    }

    /// Asks once per category for sprite data so transcript stickers can play.
    func requestStickerArt(category: UInt64) {
        guard category != 0, supports("sticker_pack"), !stickerArtCategories.contains(category) else { return }
        stickerArtCategories.insert(category)
        if let request = send("sticker_pack", parameters: ["cate_id": .number(Double(category))]) { stickerArtRequests.insert(request) }
    }
}

/// Plays a horizontal sprite strip frame by frame, as Zalo PC animates stickers.
struct SpriteSticker: View {
    let spriteURL: URL
    let frames: Int
    let duration: Double
    var size: CGFloat = 120
    var playing = true
    @State private var sprite: NSImage?
    var body: some View {
        Group {
            if let sprite {
                TimelineView(.animation(minimumInterval: duration / Double(frames), paused: !playing)) { context in
                    let frame = playing ? Int(context.date.timeIntervalSinceReferenceDate / (duration / Double(frames))) % frames : 0
                    Image(nsImage: sprite).resizable().interpolation(.high)
                        .frame(width: size * CGFloat(frames), height: size)
                        .offset(x: -CGFloat(frame) * size)
                        .frame(width: size, height: size, alignment: .leading)
                        .clipped()
                }
            } else { Color.clear }
        }
        .frame(width: size, height: size)
        .task(id: spriteURL) { sprite = await AnimatedImageCache.image(for: spriteURL) }
    }
}

/// Transcript sticker: animated when sprite data is known, the static image otherwise.
struct TranscriptSticker: View {
    @EnvironmentObject private var store: AppStore
    let message: MessageSnapshot
    let fallback: URL
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.transcriptMediaActive) private var mediaActive
    var body: some View {
        Group {
            if !mediaActive {
                Color.clear.frame(width:120,height:120)
            } else if let id = message.stickerID, let art = store.stickerArt[id], let sprite = safeWebURL(art.spriteURL),
               let frames = art.totalFrames, frames > 1 {
                SpriteSticker(spriteURL: sprite, frames: frames, duration: Double(frames) * Double(art.durationMs ?? 250) / 1000,
                              playing: !reducedMotion && mediaActive)
            } else {
                AnimatedRemoteImage(url: fallback,animates: !reducedMotion && mediaActive).frame(width: 120, height: 120)
            }
        }
        .accessibilityLabel("Nhãn dán")
        .onAppear { if let category = message.stickerCategoryID, store.stickerArt[message.stickerID ?? 0] == nil { store.requestStickerArt(category: category) } }
    }
}

/// Profile card opened from an avatar in the transcript.
struct ContactProfilePopover: View {
    let userID: String
    let name: String
    let avatar: String?
    let close: () -> Void
    /// The avatar popover shows the whole profile, as Zalo's account card does.
    var body: some View { ContactProfileCard(userID: userID, fallbackName: name, fallbackAvatar: avatar, close: close) }
}
