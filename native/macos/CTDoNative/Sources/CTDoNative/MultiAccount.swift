import SwiftUI
import AppKit
import NativeBridge

/// A Zalo account signed in on this Mac whose session is kept for switching.
struct SavedAccount: Identifiable, Hashable {
    let uin: String
    let name: String
    let avatar: String?
    var id: String { uin }
}

/// Several accounts on one Mac, one active at a time, as in the egui client (`account_manager.rs`).
///
/// The active session lives in `session.json`; each account's session is kept beside its history as
/// `accounts/<uin>.json` (owner-only permissions, never inside the repository). Switching stops the
/// worker, swaps the session file and starts it again. Only the active account stays connected, so
/// the others receive nothing until switched to.
/// Display name and photo of each account on this Mac, kept in preferences (no secrets) because a QR
/// sign-in's session file has neither.
enum AccountNames {
    private static let key = "nativeAccountProfiles"
    static func lookup(_ uin: String) -> (name: String?, avatar: String?) {
        let entry = (UserDefaults.standard.dictionary(forKey: key)?[uin] as? [String: String]) ?? [:]
        return (entry["name"].flatMap { $0.isEmpty ? nil : $0 }, entry["avatar"].flatMap { $0.isEmpty ? nil : $0 })
    }
    static func remember(_ session: SessionSnapshot) {
        guard AccountFiles.isAccountID(session.uin), !session.name.isEmpty || session.avatar != nil else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var entry = (all[session.uin] as? [String: String]) ?? [:]
        if !session.name.isEmpty { entry["name"] = session.name }
        if let avatar = session.avatar, safeWebURL(avatar) != nil { entry["avatar"] = avatar }
        all[session.uin] = entry
        UserDefaults.standard.set(all, forKey: key)
    }
}

enum AccountFiles {
    static func directory(_ base: URL) -> URL { base.appendingPathComponent("accounts", isDirectory: true) }
    static func session(_ base: URL) -> URL { base.appendingPathComponent("session.json") }
    static func saved(_ base: URL, _ uin: String) -> URL { directory(base).appendingPathComponent("\(uin).json") }

    static func isAccountID(_ uin: String) -> Bool { !uin.isEmpty && uin.count <= 32 && uin.allSatisfy(\.isNumber) }

    /// Account identity read from a session file; secrets in it are never read into the UI.
    static func identity(_ file: URL) -> SavedAccount? {
        guard let data = try? Data(contentsOf: file), data.count < 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = root["login"] as? [String: Any], let uin = login["uin"] as? String, isAccountID(uin) else { return nil }
        let known = AccountNames.lookup(uin)
        let name = (login["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? known.name ?? "Tài khoản \(uin.suffix(4))"
        let avatar = (login["avatar"] as? String).flatMap { safeWebURL($0) == nil ? nil : $0 } ?? known.avatar
        return SavedAccount(uin: uin, name: name, avatar: avatar)
    }

    static func list(_ base: URL) -> [SavedAccount] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(base), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" && isAccountID($0.deletingPathExtension().lastPathComponent) }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            .compactMap(identity)
    }

    /// Copies a session file with owner-only permissions, replacing the destination atomically.
    static func copyPrivate(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Keeps the active account's session for switching back later.
    static func snapshotActive(_ base: URL) {
        let active = session(base)
        guard let account = identity(active) else { return }
        try? copyPrivate(active, to: saved(base, account.uin))
    }
}

extension AppStore {
    var savedAccounts: [SavedAccount] { demo ? [] : AccountFiles.list(dataDirectory) }

    /// Keeps the current session and opens the QR sign-in for another account. The current account is
    /// not signed out on Zalo, so switching back needs no new QR scan.
    func addAccount() {
        guard !demo else { return }
        let base = dataDirectory
        restart {
            AccountFiles.snapshotActive(base)
            try? FileManager.default.removeItem(at: AccountFiles.session(base))
        }
    }

    func switchAccount(to uin: String) {
        guard !demo, AccountFiles.isAccountID(uin), uin != session.uin else { return }
        let base = dataDirectory
        guard FileManager.default.fileExists(atPath: AccountFiles.saved(base, uin).path) else {
            error = "Không tìm thấy phiên đã lưu của tài khoản này. Hãy thêm lại tài khoản."; return
        }
        switchingTo = savedAccounts.first { $0.uin == uin }
        restart {
            AccountFiles.snapshotActive(base)
            try? AccountFiles.copyPrivate(AccountFiles.saved(base, uin), to: AccountFiles.session(base))
        }
        // A worker that never answers must not leave the switch screen up for good.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.switchingTo?.uin == uin { self?.switchingTo = nil }
        }
    }

    /// Forgets a saved session on this Mac only; its history stays in `accounts/<uin>/`.
    func forgetAccount(_ uin: String) {
        guard AccountFiles.isAccountID(uin), uin != session.uin else { return }
        try? FileManager.default.removeItem(at: AccountFiles.saved(dataDirectory, uin))
        objectWillChange.send()
    }
}

/// Settings section listing the accounts on this Mac, with switching and adding.
struct AccountsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmAdd = false
    @State private var forgetting: SavedAccount?
    @AppStorage(AccountTabs.key) private var accountTabs = false

    private var others: [SavedAccount] { store.savedAccounts.filter { $0.uin != store.session.uin } }

    var body: some View {
        Section("Tài khoản trên máy này") {
            if store.session.loggedIn {
                HStack(spacing: 10) {
                    AvatarView(name: store.session.name, url: store.session.avatar, size: 32)
                    Text(verbatim: store.session.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Đang dùng").font(.caption.weight(.medium)).foregroundStyle(.tint)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            ForEach(others) { account in
                HStack(spacing: 10) {
                    AvatarView(name: account.name, url: account.avatar, size: 32)
                    Text(verbatim: account.name).font(.system(size: 13))
                    Spacer()
                    Button("Chuyển sang") { store.switchAccount(to: account.uin) }
                }
                .contextMenu { Button("Gỡ khỏi máy này…", role: .destructive) { forgetting = account } }
            }
            Button { confirmAdd = true } label: { Label("Thêm tài khoản…", systemImage: "person.badge.plus") }
                .disabled(store.demo)
            Toggle("Hiện thanh tài khoản trên danh sách hội thoại", isOn: $accountTabs)
            Text("Mỗi lúc chỉ một tài khoản được kết nối; tài khoản khác không nhận tin nhắn hay thông báo cho tới khi bạn chuyển sang. Phiên đăng nhập được lưu trong thư mục dữ liệu trên máy này.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Thêm tài khoản Zalo khác?", isPresented: $confirmAdd, titleVisibility: .visible) {
            Button("Thêm tài khoản") { store.addAccount() }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Tài khoản hiện tại được giữ lại để chuyển về sau, không bị đăng xuất. Bạn sẽ quét mã QR cho tài khoản mới.") }
        .alert("Gỡ \(forgetting?.name ?? "tài khoản") khỏi máy này?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Hủy", role: .cancel) { forgetting = nil }
            Button("Gỡ", role: .destructive) { if let account = forgetting { store.forgetAccount(account.uin) }; forgetting = nil }
        } message: { Text("Phiên đăng nhập đã lưu bị xóa; lịch sử tin nhắn trên máy vẫn được giữ. Muốn dùng lại cần quét mã QR.") }
    }
}

/// App-menu entries for switching accounts.
struct AccountMenuItems: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Menu("Chuyển tài khoản") {
            ForEach(store.savedAccounts.filter { $0.uin != store.session.uin }) { account in
                Button(account.name) { store.switchAccount(to: account.uin) }
            }
            Divider()
            Button("Thêm tài khoản…") { store.addAccount() }
        }
        .disabled(store.demo)
    }
}

/// The active account's photo beside the search button; opens the list of accounts on this Mac.
/// Unread messages another account on this Mac had when it was last connected. Only the active
/// account is connected, so this is read from that account's saved conversation list and counted
/// the way the core counts its badge: unread messages in conversations that are neither muted nor
/// hidden, and one for a conversation marked unread.
struct AccountUnread: Equatable {
    let count: Int
    let asOf: Date
    /// Checked with Zalo just now, rather than read from the saved list.
    var live = false
    /// The saved session of that account no longer works; it needs signing in again.
    var expired = false

    static func read(_ base: URL, uin: String) -> AccountUnread? {
        let file = AccountFiles.directory(base).appendingPathComponent(uin, isDirectory: true).appendingPathComponent("native_threads.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 64 * 1024 * 1024,
              let threads = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSince1970
        var total = 0
        for thread in threads {
            let unread = thread["unread"] as? [String: Any] ?? [:]
            let presentation = thread["presentation"] as? [String: Any] ?? [:]
            if presentation["hidden"] as? Bool == true { continue }
            if unread["muted"] as? Bool == true {
                let until = (unread["muted_until"] as? NSNumber)?.doubleValue
                if until.map({ $0 > now }) ?? true { continue }
            }
            let ids = (unread["unread_ids"] as? [Any])?.count ?? 0
            total += max(ids, unread["marked_unread"] as? Bool == true ? 1 : 0)
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return AccountUnread(count: total, asOf: modified)
    }

    /// Saved counts of every other account, read off the main thread.
    @MainActor static func saved(_ store: AppStore) async -> [String: AccountUnread] {
        let base = store.dataDirectory
        let accounts = store.savedAccounts.map(\.uin).filter { $0 != store.session.uin }
        return await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: accounts.compactMap { uin in AccountUnread.read(base, uin: uin).map { (uin, $0) } })
        }.value
    }
}

/// Account tabs above the conversation list (Cài đặt → Tài khoản & khóa, off by default): every
/// account on this Mac with its unread count, one click to switch.
struct AccountTabs: View {
    static let key = "nativeAccountTabs"
    @EnvironmentObject private var store: AppStore
    @State private var saved: [String: AccountUnread] = [:]
    private var merged: [String: AccountUnread] { saved.merging(store.liveAccountUnread) { _, live in live } }

    var body: some View {
        let others = store.savedAccounts.filter { $0.uin != store.session.uin }
        if !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tab(name: store.session.name.isEmpty ? "Tài khoản này" : store.session.name, avatar: store.session.avatar, current: true, unread: nil) {}
                    ForEach(others) { account in
                        tab(name: account.name, avatar: account.avatar, current: false, unread: merged[account.uin]) {
                            store.switchAccount(to: account.uin)
                        }
                    }
                }
                // Same inset as the conversation rows below, clear of the card's rounded top.
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            }
            .task(id: store.session.uin) { saved = await AccountUnread.saved(store) }
        }
    }

    private func tab(name: String, avatar: String?, current: Bool, unread: AccountUnread?, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 7) {
                AvatarView(name: name, url: avatar, size: 24)
                Text(verbatim: name.split(separator: " ").last.map(String.init) ?? name)
                    .font(.system(size: 12.5, weight: current ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(current ? Color.accentColor : Color.primary)
                if let unread, unread.count > 0 {
                    Text(unread.count > 99 ? "99+" : "\(unread.count)")
                        .font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.leading, 4).padding(.trailing, 11)
            .frame(height: 32)
            .background(current ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
            .overlay { Capsule().strokeBorder(current ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The active account is not dimmed like a disabled button; it simply does nothing.
        .allowsHitTesting(!current)
        .help(current ? "Đang dùng \(name)" : unread?.expired == true ? "\(name): cần đăng nhập lại" : "Chuyển sang \(name)")
    }
}

struct AccountSwitcherButton: View {
    @EnvironmentObject private var store: AppStore
    @OpenSettingsCompat private var openSettings
    @State private var open = false
    /// Saved unread counts of the other accounts, by UIN.
    @State private var unread: [String: AccountUnread] = [:]
    /// Background checks win over the saved lists; the saved list covers accounts not yet checked.
    private var merged: [String: AccountUnread] { unread.merging(store.liveAccountUnread) { _, live in live } }
    private var othersUnread: Int { merged.filter { $0.key != store.session.uin }.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        Button { open.toggle() } label: {
            AvatarView(name: store.session.name, url: store.session.avatar, size: 30)
                .frame(width: 36, height: 36).contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    // Another account has unread messages: a small dot, as Zalo shows on its switcher.
                    if othersUnread > 0 {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5) }
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain).nativeGlass(18)
        .help(othersUnread > 0 ? "Tài khoản khác có \(othersUnread) tin chưa đọc" : "Tài khoản: \(store.session.name.isEmpty ? "Zalo" : store.session.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
        .task(id: store.session.uin) { await refresh() }
        .onValueChange(of: open) { _, isOpen in if isOpen { Task { await refresh() } } }
    }

    private func refresh() async {
        let next = await AccountUnread.saved(store)
        if next != unread { unread = next }
    }

    private var list: some View {
        let others = store.savedAccounts.filter { $0.uin != store.session.uin }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Tài khoản").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            row(name: store.session.name.isEmpty ? "Tài khoản đang dùng" : store.session.name, avatar: store.session.avatar, current: true) {}
            ForEach(others) { account in
                row(name: account.name, avatar: account.avatar, current: false, unread: merged[account.uin]) {
                    open = false; store.switchAccount(to: account.uin)
                }
            }
            Divider().padding(.vertical, 4)
            menuRow("Thêm tài khoản…", "person.badge.plus") { open = false; store.addAccount() }
            menuRow("Quản lý tài khoản…", "gearshape") {
                open = false; store.requestedSettingsPage = "security"; NSApp.activate(ignoringOtherApps: true); openSettings()
            }
        }
        .padding(8).frame(width: 280)
        .materialPresentationBackground()
    }

    private func row(name: String, avatar: String?, current: Bool, unread: AccountUnread? = nil, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                AvatarView(name: name, url: avatar, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name).font(.system(size: 13, weight: current || (unread?.count ?? 0) > 0 ? .semibold : .regular)).lineLimit(1)
                    if current {
                        Text("Đang dùng").font(.system(size: 11)).foregroundStyle(.tint)
                    } else if let unread, unread.expired {
                        Text("Cần đăng nhập lại để xem tin mới").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                    } else if let unread, unread.count > 0 {
                        // A live check says when it ran; a saved list says when that account was last used.
                        Text(unread.live ? "\(unread.count) tin chưa đọc · kiểm tra \(unread.asOf.formatted(.relative(presentation: .named)))"
                                         : "\(unread.count) tin chưa đọc · đến \(unread.asOf.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if current { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.tint) }
                else if let unread, unread.count > 0 {
                    Text(unread.count > 99 ? "99+" : "\(unread.count)")
                        .font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle()).disabled(current)
    }

    private func menuRow(_ title: String, _ icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

/// Shown while the worker restarts for another account, in place of the sign-in screen.
struct AccountSwitchingView: View {
    let account: SavedAccount
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 14) {
            AvatarView(name: account.name, url: account.avatar, size: 72)
                .overlay { Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 3).padding(-5) }
                .scaleEffect(appeared || reducedMotion ? 1 : 0.9)
            Text("Đang chuyển sang \(account.name)…").font(.title3.weight(.semibold))
            ProgressView().controlSize(.small)
        }
        .opacity(appeared || reducedMotion ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { appeared = true } }
        .accessibilityElement(children: .combine)
    }
}
