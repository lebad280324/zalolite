import AppKit
import MapKit
import SwiftUI
import NativeBridge

// MARK: - Profiles

/// Profile data returned by the worker's `get_profile` intent.
struct ProfileInfo {
    let value: JSONValue
    var name: String? { value["display_name"]?.string }
    var avatar: String? { value["avatar"]?.string }
    var cover: String? { value["cover"]?.string }
    var phone: String? { value["phone"]?.string }
    var status: String? { value["status"]?.string }
    var friendship: String { value["friendship"]?.string ?? "Unknown" }
    var isStranger: Bool { ["Stranger", "OutgoingPending", "IncomingPending"].contains(friendship) && !isOfficial }
    /// Official accounts (pages) take no friend requests.
    var isOfficial: Bool { value["is_official"]?.bool == true }
    var gender: String? {
        switch value["gender"]?.number.map(Int.init) {
        case 0: return "Nam"
        case 1: return "Nữ"
        default: return nil
        }
    }
    /// Zalo sends birthdays as `dd/MM/yyyy`; shown the way the Vietnamese client writes them.
    var birthday: String? {
        guard let raw = value["birthday"]?.string, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return raw }
        return "\(parts[0]) tháng \(parts[1]), \(parts[2])"
    }
}

@MainActor
extension AppStore {
    /// "Cloud của tôi" / My Documents is the account's own storage chat, never a person to befriend.
    func isSelfThread(_ thread: ThreadSnapshot) -> Bool {
        thread.id == session.uin || thread.name.hasPrefix("Cloud của tôi") || thread.name == "My Documents"
    }

    static func isGenericName(_ name: String) -> Bool {
        name.hasPrefix("Người dùng ") || name.allSatisfy(\.isNumber)
    }

    func applyProfileNames(_ incoming: [ThreadSnapshot]) -> [ThreadSnapshot] {
        incoming.map { thread in
            guard !thread.isGroup else { return thread }
            var named = thread
            if let profile = profiles[thread.id] {
                if Self.isGenericName(named.name), let name = profile.name, !name.isEmpty { named.name = name }
                if safeWebURL(named.avatar) == nil, let avatar = profile.avatar { named.avatar = avatar }
            }
            // One name, as on Zalo: the nickname set on Zalo replaces the person's own name.
            let alias = aliases[thread.id] ?? features.thread(thread.id)?.string("alias") ?? ""
            if !alias.isEmpty, named.name != alias {
                originalNames[thread.id] = named.name
                named.name = alias
            }
            return named
        }
    }

    /// Recent one-to-one chats that only have an ID get their real name, a few at a time.
    func prefetchProfilesForUnnamedThreads(_ list: [ThreadSnapshot]) {
        let unnamed = list.filter { !$0.isGroup && !$0.hidden && Self.isGenericName($0.name) && !isSelfThread($0) && profiles[$0.id] == nil }
            .sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }.prefix(20)
        for thread in unnamed { requestProfile(thread.id) }
    }

    /// Fetches a person's profile once per session; a stale answer is simply replaced.
    func requestProfile(_ userID: String, force: Bool = false) {
        guard !userID.isEmpty, userID.allSatisfy(\.isNumber), userID != session.uin, supports("get_profile") else { return }
        guard force || (profiles[userID] == nil && !profileRequests.contains(userID)) else { return }
        profileRequests.insert(userID)
        send("get_profile", parameters: ["user_id": .string(userID)])
    }

    /// A QR sign-in carries no display name or photo; read this account's own profile once.
    func requestOwnProfile() {
        guard session.loggedIn, AccountFiles.isAccountID(session.uin), supports("get_profile"), !profileRequests.contains(session.uin) else { return }
        profileRequests.insert(session.uin)
        send("get_profile", parameters: ["user_id": .string(session.uin)])
    }

    func handleProfileResult(_ data: JSONValue?) {
        guard let data, let id = data["user_id"]?.string else { return }
        profileRequests.remove(id)
        profiles[id] = ProfileInfo(value: data)
        if id == session.uin {
            let info = ProfileInfo(value: data)
            if session.name.isEmpty, let name = info.name, !name.isEmpty { session.name = name }
            if safeWebURL(session.avatar) == nil, let avatar = info.avatar { session.avatar = avatar }
            AccountNames.remember(session)
        }
        // A conversation known only by its ID takes the real name and photo.
        let named = applyProfileNames(threads)
        if named != threads { threads = named }
    }
}

/// People who refused this account's messages (Zalo error 119), per account. Zalo has no read for
/// "blocked by", so the mark is learnt from a refused send and cleared by the next accepted one.
enum BlockedBy {
    private static func key(_ account: String) -> String { "nativeBlockedBy.\(account)" }
    static func load(account: String) -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: key(account)) ?? []).filter(AccountFiles.isAccountID))
    }
    static func save(_ ids: Set<String>, account: String) {
        UserDefaults.standard.set(ids.sorted(), forKey: key(account))
    }
}

extension AppStore {
    /// This account has blocked the person (Zalo block list).
    func hasBlocked(_ userID: String) -> Bool { features.blockedContacts.contains { $0.id == userID } }
    /// Asks Zalo for the original photo behind a profile picture; the viewer swaps to it when it comes.
    func requestFullAvatar(_ userID: String) {
        guard !demo, supports("full_avatar"), fullAvatars[userID] == nil, AccountFiles.isAccountID(userID) else { return }
        send("full_avatar", parameters: ["user_id": .string(userID)])
    }

    /// A page (official account): Zalo says so, or its messages are page articles.
    func looksOfficial(_ threadID: String) -> Bool {
        if profiles[threadID]?.isOfficial == true { return true }
        return (messages[threadID] ?? []).contains { message in
            !message.isOutgoing && (safeWebURL(message.linkURL)?.host?.hasSuffix("officialaccount.me") == true
                || safeWebURL(message.linkURL)?.host == "oa.zalo.me")
        }
    }
    /// The person refused this account's messages.
    func isBlockedBy(_ userID: String) -> Bool { sendBlocked.contains(userID) }
}

/// Zalo-style bar for a one-to-one chat with someone who is not yet a friend.
struct StrangerBanner: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    var body: some View {
        if !thread.isGroup, !store.isSelfThread(thread), let profile = store.profiles[thread.id], profile.isStranger,
           !store.hasBlocked(thread.id), !store.isBlockedBy(thread.id), !store.looksOfficial(thread.id) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 17)).foregroundStyle(Color.accentColor)
                Text(message(profile)).font(.system(size: 13)).lineLimit(2)
                Spacer(minLength: 6)
                switch profile.friendship {
                case "OutgoingPending":
                    if store.supports("undo_friend") {
                        Button("Thu hồi lời mời") { act("undo_friend") }.buttonStyle(.bordered).controlSize(.small).capsuleButtonShape()
                    }
                case "IncomingPending":
                    if store.supports("reject_friend") { Button("Từ chối") { act("reject_friend") }.buttonStyle(.bordered).controlSize(.small).capsuleButtonShape() }
                    if store.supports("accept_friend") { Button("Đồng ý") { act("accept_friend") }.buttonStyle(.borderedProminent).controlSize(.small).capsuleButtonShape() }
                default:
                    if store.supports("add_friend") {
                        Button("Gửi kết bạn") { act("add_friend") }.buttonStyle(.borderedProminent).controlSize(.small).capsuleButtonShape()
                            .disabled(store.busy.contains("add_friend"))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            // Liquid Glass, like the header controls; a light tint keeps the text readable over messages.
            .nativeGlass(20)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    private func message(_ profile: ProfileInfo) -> String {
        switch profile.friendship {
        case "OutgoingPending": return "Đã gửi lời mời kết bạn, đang chờ đồng ý"
        case "IncomingPending": return "Người này đã gửi lời mời kết bạn cho bạn"
        default: return "Gửi yêu cầu kết bạn tới người này"
        }
    }
    private func act(_ command: String) {
        store.send(command, parameters: ["user_id": .string(thread.id)])
        // The friendship is re-read so the bar reflects what Zalo accepted.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            store.requestProfile(thread.id, force: true)
        }
    }
}

/// Full profile card, as Zalo's "Thông tin tài khoản": cover, identity, details and actions.
struct ContactProfileCard: View {
    @EnvironmentObject private var store: AppStore
    let userID: String
    let fallbackName: String
    let fallbackAvatar: String?
    let close: () -> Void
    @Environment(\.popoverMaxHeight) private var maxHeight
    @State private var sharing = false
    private var profile: ProfileInfo? { store.profiles[userID] }
    private var name: String { profile?.name ?? fallbackName }
    private var avatar: String? { profile?.avatar ?? fallbackAvatar }
    private var alias: String { store.features.thread(userID)?.string("alias") ?? "" }
    private var direct: ThreadSnapshot? { store.threads.first { $0.id == userID && !$0.isGroup } }
    private var commonGroups: [ThreadSnapshot] {
        store.threads.filter { group in group.isGroup && (store.features.members[group.id] ?? []).contains { $0.id == userID } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    // The cover fills the full card width, cropped like Zalo's banner.
                    Color.clear.frame(height: 130).frame(maxWidth: .infinity)
                        .overlay {
                            if let cover = safeWebURL(profile?.cover) {
                                AsyncImage(url: cover) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { coverPlaceholder }
                                }
                            } else { coverPlaceholder }
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { if let cover = safeWebURL(profile?.cover) { view(cover) } }
                        .help(safeWebURL(profile?.cover) == nil ? "" : "Xem ảnh bìa")
                    AvatarView(name: name, url: avatar, size: 84)
                        .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 3) }
                        .contentShape(Circle())
                        .onTapGesture { if let url = safeWebURL(store.fullAvatars[userID]) ?? safeWebURL(avatar) { view(url); store.requestFullAvatar(userID) } }
                        .help(safeWebURL(avatar) == nil ? "" : "Xem ảnh đại diện")
                        .offset(x: 18, y: 42)
                }
                .padding(.bottom, 46)
                HStack(spacing: 6) {
                    Text(verbatim: alias.isEmpty ? name : alias).font(.system(size: 19, weight: .bold)).lineLimit(2)
                    if let direct, store.supports("update_alias") {
                        Button { store.aliasThread = direct; close() } label: { Image(systemName: "pencil").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Đặt tên gợi nhớ")
                    }
                    if store.hasBlocked(userID) {
                        badge("ĐÃ CHẶN", .red)
                    } else if store.isBlockedBy(userID) {
                        badge("ĐÃ CHẶN BẠN", .red)
                    } else if profile?.isStranger == true {
                        Text("NGƯỜI LẠ").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    }
                }.padding(.horizontal, 18)
                if !alias.isEmpty && alias != name { Text("Tên Zalo: \(name)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18) }
                if let status = profile?.status { Text(verbatim: status).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 4) }
                if blocked { blockNotice }
                HStack(spacing: 10) {
                    if let direct, store.supports("start_call"), !blocked {
                        Button { store.selectThread(direct.id); store.startCall(video: false); close() } label: { Text("Gọi điện").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    Button { store.openDirect(userID: userID, name: name, avatar: avatar); close() } label: { Text("Nhắn tin").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(.horizontal, 18).padding(.vertical, 14)
                if profile?.isStranger == true && profile?.friendship == "Stranger" && store.supports("add_friend") && !blocked {
                    Button { store.send("add_friend", parameters: ["user_id": .string(userID)]); refreshSoon() } label: {
                        Label("Gửi lời mời kết bạn", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).padding(.horizontal, 18).padding(.bottom, 12)
                }
                section("Thông tin cá nhân") {
                    row("Giới tính", profile?.gender)
                    row("Ngày sinh", profile?.birthday)
                    row("Điện thoại", profile?.phone)
                    if profile != nil && profile?.value["full_profile"]?.bool == false {
                        Text("Zalo chỉ chia sẻ đầy đủ thông tin với bạn bè.").font(.caption).foregroundStyle(.secondary)
                    }
                    if profile == nil { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    action("person.2", "Nhóm chung (\(commonGroups.count))", enabled: !commonGroups.isEmpty) {
                        if let group = commonGroups.first { store.selectThread(group.id); close() }
                    }
                    if store.supports("send_contact") {
                        action("person.text.rectangle", "Chia sẻ danh thiếp") { sharing.toggle() }
                            .popover(isPresented: $sharing) { shareTargets }
                    }
                    if store.supports("set_contact_blocked") && store.hasBlocked(userID) {
                        action("hand.raised.slash", "Bỏ chặn") {
                            store.send("set_contact_blocked", parameters: ["user_id": .string(userID), "blocked": .bool(false)])
                        }
                    } else if store.supports("set_contact_blocked") {
                        action("nosign", "Chặn tin nhắn và cuộc gọi", destructive: true) {
                            store.blockCandidate = FeatureRow(value: .object(["id": .string(userID), "name": .string(name)])); close()
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .frame(width: 380, height: min(600, maxHeight))
        .onAppear { store.requestProfile(userID) }
    }

    private var blocked: Bool { store.hasBlocked(userID) || store.isBlockedBy(userID) }

    /// Opens a photo in the in-window viewer, closing the card first.
    private func view(_ url: URL) {
        close()
        NotificationCenter.default.post(name: .openImageViewer, object: url)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    private var blockNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "nosign").foregroundStyle(.red).font(.system(size: 13, weight: .semibold))
            Text(store.hasBlocked(userID)
                 ? "Bạn đã chặn người này. Hai bên không nhắn tin hay gọi cho nhau được cho tới khi bạn bỏ chặn."
                 : "Người này đã chặn bạn hoặc không nhận tin nhắn từ bạn. Zalo từ chối tin nhắn và cuộc gọi tới họ.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 18).padding(.top, 10)
    }

    private var coverPlaceholder: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.purple.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var shareTargets: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Gửi danh thiếp tới").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(8)
            ForEach(Array(store.threads.filter { !$0.hidden && $0.id != userID }.sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }.prefix(8))) { target in
                Button {
                    store.send("send_contact", parameters: ["thread_id": .string(target.id), "contact_id": .string(userID)], threadID: target.id)
                    sharing = false
                } label: {
                    HStack(spacing: 8) { ThreadAvatar(thread: target, size: 24); Text(verbatim: target.name).lineLimit(1); Spacer() }
                        .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(6).frame(width: 260)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Text(verbatim: value).textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(.system(size: 13))
        }
    }

    private func action(_ icon: String, _ title: String, enabled: Bool = true, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(destructive ? Color.red : Color.secondary)
                Text(title).foregroundStyle(destructive ? Color.red : enabled ? Color.primary : Color.secondary)
                Spacer()
            }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func refreshSoon() {
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_200_000_000); store.requestProfile(userID, force: true) }
    }
}

// MARK: - Location

/// A shared point, read from the worker's `maps.google.com/maps?q=lat,lo` link.
struct LocationPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let title: String

    init?(_ message: MessageSnapshot) {
        guard message.messageType == "chat.location", let link = message.linkURL,
              let query = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        let parts = query.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        latitude = parts[0]; longitude = parts[1]
        let text = (message.linkTitle ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        title = text.isEmpty || text == "[Vị trí]" ? "Vị trí được chia sẻ" : text
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var appleMaps: URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [.init(name: "ll", value: "\(latitude),\(longitude)"), .init(name: "q", value: title)]
        return parts?.url
    }
    var googleMaps: URL? { URL(string: "https://maps.google.com/maps?q=\(latitude),\(longitude)&z=15") }
}

/// Map snapshots are drawn locally by MapKit, so no map provider key or web view is involved.
@MainActor
enum MapSnapshotCache {
    private static var images: [String: NSImage] = [:]
    static func image(for point: LocationPoint, size: CGSize, dark: Bool) async -> NSImage? {
        let key = "\(point.latitude),\(point.longitude),\(Int(size.width))x\(Int(size.height)),\(dark)"
        if let hit = images[key] { return hit }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: point.coordinate, latitudinalMeters: 700, longitudinalMeters: 700)
        options.size = size
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let image = try? await MKMapSnapshotter(options: options).start().image
        if let image { images[key] = image }
        return image
    }
}

struct LocationCard: View {
    let point: LocationPoint
    let senderName: String
    let senderAvatar: String?
    @Environment(\.colorScheme) private var scheme
    @State private var snapshot: NSImage?
    private let size = CGSize(width: 280, height: 150)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if let url = point.appleMaps { NSWorkspace.shared.open(url) } } label: {
                ZStack {
                    Color.primary.opacity(0.06)
                    if let snapshot { Image(nsImage: snapshot).resizable().scaledToFill() } else { ProgressView().controlSize(.small) }
                    // The sender's avatar marks the point, as Zalo does.
                    VStack(spacing: 0) {
                        AvatarView(name: senderName, url: senderAvatar, size: 34)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(.white).offset(y: -2)
                    }.offset(y: -14)
                }
                .frame(width: size.width, height: size.height).clipped()
                .overlay(alignment: .topLeading) {
                    Label("Bản đồ", systemImage: "arrow.up.forward.square").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.regularMaterial, in: Capsule()).padding(8)
                }
            }.buttonStyle(.plain).help("Mở trong Bản đồ")
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(verbatim: point.title).lineLimit(3) } icon: { Image(systemName: "mappin.and.ellipse").foregroundStyle(.red) }
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Button("Apple Maps") { if let url = point.appleMaps { NSWorkspace.shared.open(url) } }
                    Button("Google Maps") { if let url = point.googleMaps { NSWorkspace.shared.open(url) } }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(point.title, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                        .help("Sao chép địa chỉ")
                }.buttonStyle(.bordered).controlSize(.small)
            }.padding(11)
        }
        .frame(width: size.width)
        .background(Color.bubbleIncoming, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .task(id: scheme) { snapshot = await MapSnapshotCache.image(for: point, size: size, dark: scheme == .dark) }
    }
}

// MARK: - Links

/// Link preview card: site, title and URL in a card that cannot be mistaken for a typed message.
struct LinkCard: View {
    let url: URL
    let title: String?
    let thumbnail: URL?
    /// Shown inside the card when it stands alone; omitted when the card sits in a text bubble.
    let time: Date?
    @State private var hovering = false
    private var host: String { (url.host ?? "Liên kết").replacingOccurrences(of: "www.", with: "") }
    private var heading: String {
        let value = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == url.absoluteString ? host : value
    }
    private var path: String {
        let value = url.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        return value.count > 60 ? String(value.prefix(57)) + "…" : value
    }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12))
                    if let thumbnail {
                        AsyncImage(url: thumbnail) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { Image(systemName: "globe").font(.system(size: 20)).foregroundStyle(Color.accentColor) }
                        }
                    } else {
                        Image(systemName: "link").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: heading).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(verbatim: path).font(.system(size: 11.5)).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Image(systemName: "safari").font(.system(size: 10))
                        Text(verbatim: host).font(.system(size: 11)).lineLimit(1)
                        if let time {
                            Spacer(minLength: 6)
                            Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().opacity(0.82)
                        }
                    }.foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(width: 300, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.45 : 0.18), lineWidth: 1) }
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
        .contextMenu {
            Button("Mở liên kết") { NSWorkspace.shared.open(url) }
            Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }
}
