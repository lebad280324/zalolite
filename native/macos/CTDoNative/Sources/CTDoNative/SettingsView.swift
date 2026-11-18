import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeBridge

private enum SettingsPage: String, CaseIterable, Identifiable {
 case general = "Chung", updates = "Cập nhật phần mềm", security = "Tài khoản & khóa", privacy = "Quyền riêng tư", sync = "Đồng bộ & sao lưu", storage = "Dung lượng", appearance = "Giao diện", notifications = "Thông báo", messages = "Tin nhắn", calls = "Cuộc gọi", utilities = "Tiện ích", ai = "Trợ lý AI"
 var id: String { rawValue }
 /// Stable key used by deep links from the workspace.
 var key: String {
  switch self { case .general: return "general"; case .updates: return "updates"; case .security: return "security"; case .privacy: return "privacy"; case .sync: return "sync"; case .storage: return "storage"; case .appearance: return "appearance"; case .notifications: return "notifications"; case .messages: return "messages"; case .calls: return "calls"; case .utilities: return "utilities"; case .ai: return "ai" }
 }
 /// Individual options on the page, so search finds a setting and not only a page title.
 var keywords: [String] {
  switch self {
  case .general: return ["Ngôn ngữ", "Mở khi đăng nhập macOS", "Ghi nhớ tài khoản", "Kết nối lại"]
  case .updates: return ["Phiên bản", "Kiểm tra cập nhật", "Tự động kiểm tra", "Bản mới"]
  case .security: return ["Khóa ứng dụng", "Hình nền màn hình khóa", "Phím tắt khóa", "Bảo mật hai lớp", "Đăng xuất", "Mã PIN hội thoại ẩn"]
  case .privacy: return ["Ngày sinh", "Trạng thái truy cập", "Trạng thái đã xem", "Người được nhắn tin", "Người được gọi", "Danh sách chặn", "Tìm qua số điện thoại", "Nguồn kết bạn", "Đang soạn"]
  case .sync: return ["Đồng bộ từ điện thoại", "Xuất bản sao", "Nhập lịch sử", "Sao lưu"]
  case .storage: return ["Dung lượng", "Bộ nhớ đệm", "Dọn dữ liệu", "Ổ đĩa", "Thư mục dữ liệu", "Hủy tải"]
  case .appearance: return ["Sáng", "Tối", "Theo hệ thống", "Avatar làm nền", "Ảnh thu nhỏ", "Cỡ chữ", "Font", "Phông chữ"]
  case .notifications: return ["Quyền thông báo", "Âm thanh", "Xem trước nội dung", "Huy hiệu Dock", "Cuộc gọi đến"]
  case .messages: return ["Tin nhắn nhanh", "Mẫu tin", "Ưu tiên và Khác", "Thư mục lưu tệp", "Nhấp đúp để trả lời", "Return để gửi", "Tải trước media", "Dán Excel", "Ảnh thu nhỏ"]
  case .calls: return ["Micrô", "Camera", "Loa", "Thông báo cuộc gọi đến", "Quyền thiết bị"]
  case .utilities: return ["Chụp màn hình", "Gợi ý nhãn dán", "Gợi ý @", "Nhắc tên", "Emoji", "GIF"]
  case .ai: return ["Trợ lý AI", "Codex", "Claude", "MCP", "Chia sẻ hội thoại", "Tổng hợp công việc"]
  }
 }
 func match(_ query: String) -> String? { keywords.first { $0.localizedStandardContains(query) } }
 /// Tile colours follow the system settings palette so pages are recognisable at a glance.
 var tint: Color {
  switch self {
  case .general: return .gray; case .updates: return .blue; case .security: return .blue; case .privacy: return .indigo; case .sync: return .green
  case .storage: return Color(red: 0.45, green: 0.47, blue: 0.52); case .appearance: return .purple; case .notifications: return .red
  case .messages: return Color(red: 0.2, green: 0.78, blue: 0.35); case .calls: return .teal; case .utilities: return .orange; case .ai: return .pink
  }
 }
 var summary: String {
  switch self {
  case .general: return "Ngôn ngữ, khởi động và kết nối của ứng dụng."
  case .updates: return "Phiên bản Zalolite và bản cập nhật mới."
  case .security: return "Khóa ứng dụng trên máy này và bảo mật tài khoản Zalo."
  case .privacy: return "Ai được xem thông tin và liên hệ với bạn."
  case .sync: return "Đồng bộ từ điện thoại, xuất và nhập bản sao lưu."
  case .storage: return "Dung lượng dữ liệu và thư mục lưu trên máy."
  case .appearance: return "Chế độ màu, cỡ chữ và hình nền cuộc trò chuyện."
  case .notifications: return "Thông báo tin nhắn, âm thanh và huy hiệu."
  case .messages: return "Cách soạn, đọc và lưu tin nhắn."
  case .calls: return "Micrô, camera và thông báo cuộc gọi."
  case .utilities: return "Gợi ý khi soạn và chụp màn hình."
  case .ai: return "Cho trợ lý AI trên máy đọc các hội thoại bạn chọn."
  }
 }
 var icon: String {
  switch self { case .general: return "switch.2"; case .updates: return "arrow.down.circle"; case .security: return "lock.shield"; case .privacy: return "hand.raised"; case .sync: return "arrow.triangle.2.circlepath"; case .storage: return "internaldrive"; case .appearance: return "paintpalette"; case .notifications: return "bell.badge"; case .messages: return "bubble.left"; case .calls: return "video"; case .utilities: return "slider.horizontal.3"; case .ai: return "sparkles" }
 }
}

struct SettingsView: View {
 @EnvironmentObject private var store: AppStore
 @StateObject private var system = NativeSystem()
 @ObservedObject private var updater = SoftwareUpdater.shared
 @State private var page = SettingsPage.general
 @State private var search = ""
 @State private var pendingKey: String?
 @State private var pendingValue = 0
 @State private var pendingLabel = ""
 @State private var twoFactorSheet = false
 @State private var otp = ""
 @State private var clearCacheConfirmation = false
 @AppStorage("nativeAppearance") private var appearance = "system"
 @AppStorage("nativeNotificationSound") private var notificationSound = true
 @AppStorage("nativeNotificationsEnabled") private var notifications = true
 @AppStorage("nativeDoubleClickReply") private var doubleClickReply = true
 @AppStorage("nativeShowThumbnails") private var thumbnails = true
 @AppStorage("nativeSendWithReturn") private var sendWithReturn = true
 @AppStorage("nativeStickerSuggestions") private var stickerSuggestions = true
 @AppStorage("nativeLockOnDeactivate") private var lockOnDeactivate = false
 @AppStorage("nativeCaptureKey") private var captureKey = "s"
 @AppStorage("nativeCaptureHiddenKey") private var captureHiddenKey = "a"
 @AppStorage("nativeMentionSuggestions") private var mentionSuggestions = true
 @AppStorage("nativePrioritySplit") private var prioritySplit = false
 @AppStorage("nativeNotificationPreview") private var notificationPreview = true
 @AppStorage("nativeCallNotifications") private var callNotifications = true
 @AppStorage("nativeDockBadge") private var dockBadge = true
 @AppStorage(BackgroundMode.keepRunningKey) private var keepRunning = true
 @AppStorage("nativeImportMedia") private var importMedia = false
 @AppStorage(BackgroundMode.menuBarKey) private var menuBarIcon = true
 @AppStorage(BackgroundMode.hideDockKey) private var hideDock = false
 @AppStorage("nativeDownloadDirectory") private var downloadDirectory = ""
 private var pages: [SettingsPage] {
  SettingsPage.allCases.filter { search.isEmpty || $0.rawValue.localizedStandardContains(search) || $0.match(search) != nil }
 }
 var body: some View {
  // A fixed sidebar: NavigationSplitView inside the Settings scene ignores column widths.
  HStack(spacing: 0) {
   VStack(spacing: 0) {
   HStack(spacing: 6) {
    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
    TextField("Tìm kiếm", text: $search).textFieldStyle(.plain)
    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
   }
   .padding(.horizontal, 9).padding(.vertical, 6)
   .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
   .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
   List(selection: Binding(get: { Optional(page) }, set: { if let value = $0 { page = value } })) {
    if store.session.loggedIn && search.isEmpty {
     Section {
      HStack(spacing: 10) {
       AvatarView(name: store.session.name, url: store.session.avatar, size: 36)
       VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: store.session.name.isEmpty ? "Tài khoản Zalo" : store.session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text("Tài khoản Zalo").font(.caption).foregroundStyle(.secondary)
       }
      }.padding(.vertical, 4).tag(SettingsPage.security)
     }
    }
    ForEach(pages) { item in
     HStack(spacing: 9) {
      SettingsIconTile(icon: item.icon, tint: item.tint, size: 22)
      VStack(alignment: .leading, spacing: 1) {
       Text(item.rawValue)
       if !search.isEmpty, let hit = item.match(search) { Text(verbatim: hit).font(.caption2).foregroundStyle(.secondary) }
      }
      if item == .updates, updater.available != nil {
       Spacer(minLength: 4)
       Text("Mới").font(.caption2.weight(.bold)).foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
      }
     }.tag(item)
    }
   }
   .listStyle(.sidebar)
   }
   .frame(width: 250)
   .background(.ultraThinMaterial)
   Divider()
   Form {
    Section {
     VStack(spacing: 8) {
      SettingsIconTile(icon: page.icon, tint: page.tint, size: 54)
      Text(page.rawValue).font(.system(size: 20, weight: .bold))
      Text(page.summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if !store.busy.isDisjoint(with: ["set_account_setting", "set_two_factor", "set_privacy_guard", "select_media_devices"]) {
       ProgressView("Đang lưu…").controlSize(.small)
      } else if !store.busy.isDisjoint(with: ["get_account_settings", "data_usage", "list_media_devices"]) {
       ProgressView("Đang đọc…").controlSize(.small)
      }
     }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }
    settingsContent
    if let error = system.error ?? store.error {
     Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
    }
   }
   .formStyle(.grouped)
   .frame(maxWidth: .infinity)
  }
  .navigationTitle(page.rawValue)
  .frame(minWidth: 900, idealWidth: 940, minHeight: 620, idealHeight: 680)
  .task { system.refresh(); applyRequestedPage(); refreshPage() }.onValueChange(of: page) { _, _ in refreshPage() }
  .onValueChange(of: store.requestedSettingsPage) { _, _ in applyRequestedPage() }
  .alert("Thay đổi \(pendingLabel)?", isPresented: Binding(get: { pendingKey != nil }, set: { if !$0 { pendingKey = nil } })) {
   Button("Hủy", role: .cancel) { pendingKey = nil }
   Button("Áp dụng") { if let key = pendingKey { store.send("set_account_setting", parameters: ["key": .string(key), "value": .number(Double(pendingValue))]) }; pendingKey = nil }
  } message: { Text("Thiết lập này được gửi tới tài khoản Zalo. Giá trị chỉ cập nhật sau khi máy chủ xác nhận.") }
  .confirmationDialog("Dọn bộ nhớ đệm?", isPresented: $clearCacheConfirmation, titleVisibility: .visible) {
   Button("Dọn bộ nhớ đệm", role: .destructive) { store.send("clear_cache") }; Button("Hủy", role: .cancel) {}
  } message: { Text("Chỉ dọn các tệp tạm do ứng dụng quản lý. Lịch sử tin nhắn và bản sao đã xuất được giữ lại.") }
  .sheet(isPresented: $twoFactorSheet) { twoFactorForm }
 }
 @ViewBuilder private var settingsContent: some View {
  switch page {
  case .general:
   Section("Ngôn ngữ") { LabeledContent("Ngôn ngữ đang hỗ trợ", value: "Tiếng Việt") }
   Section("Chạy nền") {
    Toggle("Tiếp tục chạy nền khi đóng cửa sổ", isOn: $keepRunning)
    Toggle("Hiện biểu tượng trên thanh menu", isOn: $menuBarIcon)
    Toggle("Ẩn biểu tượng Dock khi đã đóng cửa sổ", isOn: $hideDock).disabled(!keepRunning || !menuBarIcon)
    Text("Khi chạy nền, Zalolite vẫn giữ kết nối để nhận tin nhắn, cuộc gọi đến và đồng bộ với điện thoại; trạng thái truy cập hiển thị theo mục Quyền riêng tư. Chọn Thoát Zalolite (⌘Q) để ngắt hẳn.").font(.caption).foregroundStyle(.secondary)
   }
   Section("Khởi động") { Toggle("Mở khi đăng nhập macOS", isOn: Binding(get: { system.launchAtLogin }, set: { system.setLaunchAtLogin($0) })); Text("macOS có thể yêu cầu cho phép trong Mục đăng nhập.").font(.caption).foregroundStyle(.secondary) }
   Section("Kết nối") { LabeledContent("Trạng thái", value: store.connection); Button("Kết nối lại bộ xử lý") { store.restart() } }
  case .ai:
   AIBridgeSection()
  case .updates:
   SoftwareUpdateSection()
  case .security:
   Section("Tài khoản") {
    HStack(spacing: 14) {
     AvatarView(name: store.session.name, url: store.session.avatar, size: 58)
     VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: store.session.loggedIn ? (store.session.name.isEmpty ? "Đang tải tên tài khoản…" : store.session.name) : "Chưa đăng nhập")
       .font(.system(size: 17, weight: .semibold)).lineLimit(1)
      if store.session.loggedIn {
       Text(verbatim: "Zalo · mã tài khoản …\(store.session.uin.suffix(4))").font(.system(size: 12)).foregroundStyle(.secondary)
       Label("Đang đăng nhập trên máy này", systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.green)
      }
     }
     Spacer()
     if store.session.loggedIn { Button("Đăng xuất…", role: .destructive) { store.showingLogoutConfirmation = true }.controlSize(.large) }
    }.padding(.vertical, 4)
   }
   AccountsSection()
   Section("Khóa trên máy này") {
    Button("Khóa ngay", systemImage: "lock") { store.isLocked = true }
    LabeledContent("Phím tắt khóa", value: "⌃⌘L")
    Toggle("Khóa khi ứng dụng chuyển sang nền", isOn: $lockOnDeactivate)
    LockBackgroundPicker()
    Text("Mở khóa bằng xác thực macOS. Khóa màn hình không thay thế mã hóa dữ liệu trên ổ đĩa.").font(.caption).foregroundStyle(.secondary)
   }
   Section("Bảo mật tài khoản Zalo") {
    if store.supports("set_two_factor") {
     LabeledContent("Xác thực hai lớp", value: accountValue("setting_2FA_status").map { $0 == 1 ? "Đang bật" : "Đang tắt" } ?? "Chưa đọc được trạng thái")
     Button("Thay đổi bảo mật hai lớp…") { otp = ""; twoFactorSheet = true }.disabled(accountValue("setting_2FA_status") == nil)
    } else { unavailable("Thiết lập hai lớp chưa có kênh xác nhận tài khoản.") }
    unavailable("Mã PIN cho từng hội thoại ẩn chưa được hỗ trợ; không tạo PIN giả trên giao diện.")
   }
  case .privacy:
   Section("Quyền của tài khoản Zalo") {
    serverToggle("Hiển thị trạng thái truy cập", key: "show_online_status")
    serverToggle("Hiển thị trạng thái đã xem", key: "display_seen_status")
    serverPicker("Ngày sinh", key: "view_birthday", values: [(0,"Không hiển thị"),(1,"Đầy đủ"),(2,"Chỉ ngày và tháng")])
    serverPicker("Người được nhắn tin", key: "receive_message", values: [(1,"Mọi người"),(2,"Bạn bè")])
    serverPicker("Người được gọi", key: "accept_stranger_call", values: [(2,"Bạn bè"),(4,"Bạn bè và người đã liên hệ"),(3,"Mọi người")])
   }
   Section("Cho phép kết bạn qua") {
    serverToggle("Số điện thoại", key: "add_friend_via_phone"); serverToggle("Mã QR", key: "add_friend_via_qr"); serverToggle("Nhóm chung", key: "add_friend_via_group"); serverToggle("Danh thiếp", key: "add_friend_via_contact"); serverToggle("Gợi ý có thể quen", key: "display_on_recommend_friend")
    Button("Xem danh sách chặn") { store.showContacts(); store.contactSection = .blocked; if store.supports("list_blocked_contacts") { store.send("list_blocked_contacts") } }.disabled(!store.supports("list_blocked_contacts"))
   }
   Section("Giới hạn gửi trạng thái từ máy này") {
    guardToggle("Không gửi trạng thái đang soạn", key: "block_typing"); guardToggle("Không gửi trạng thái đã nhận", key: "block_delivered"); guardToggle("Không gửi trạng thái đã xem", key: "block_seen")
    Text("Đây là bộ chặn cục bộ, không thay đổi quyền riêng tư của tài khoản trên các thiết bị khác.").font(.caption).foregroundStyle(.secondary)
   }
  case .sync:
   Section("Đồng bộ lịch sử") {
    Text(verbatim: store.features.syncMessage).textSelection(.enabled)
    if store.features.syncing { ProgressView(value: store.features.syncProgress); Button("Dừng đồng bộ") { store.send("cancel_phone_sync") }.disabled(!store.supports("cancel_phone_sync")) }
    else { Button("Yêu cầu đồng bộ từ điện thoại") { store.send("sync_phone", parameters: ["send_phone_prompt": .bool(true)]) }.disabled(!store.supports("sync_phone") || !store.session.loggedIn) }
    Text("Số tin thực nhập được hiển thị khi kết thúc. Không đồng nghĩa toàn bộ lịch sử điện thoại đã được tải.").font(.caption).foregroundStyle(.secondary)
   }
   Section("Bản sao của bạn") { Button("Xuất bản sao lịch sử…") { store.requestBackup() }.disabled(!store.supports("export_backup")); Text("Bản xuất dùng để lưu và nhập lại trong ctdozlite; đây không phải bản sao khôi phục trực tiếp vào ứng dụng Zalo điện thoại.").font(.caption).foregroundStyle(.secondary) }
   Section("Nhập từ bản sao lưu") {
    if let progress = store.importProgress {
     ProgressView(value: progress) {
      Text(store.importPhase == "media"
           ? "Đang chép ảnh, video và tệp… \(Int(progress * 100))% · \(store.importRows) tệp"
           : "Đang nhập tin nhắn… \(Int(progress * 100))% · \(store.importRows) dòng đã đọc")
     }
     Button("Dừng nhập") { store.send("cancel_import") }.disabled(!store.supports("cancel_import"))
     Text("Giữ ứng dụng mở cho đến khi xong. Các thao tác khác tạm chờ trong lúc nhập.").font(.caption).foregroundStyle(.secondary)
    } else {
     Toggle(isOn: $importMedia) {
      VStack(alignment: .leading, spacing: 2) {
       Text("Nhập cả ảnh, video và tệp")
       Text("Chép ảnh, video, tệp trong bản sao lưu vào máy để xem cả khi không có mạng hoặc khi Zalo đã xoá bản trên máy chủ. Cần thêm dung lượng gần bằng phần media của bản sao lưu (thường vài GB). Nhập lại không chép trùng.").font(.caption).foregroundStyle(.secondary)
      }
     }
     Button("Nhập bản xuất của Zalo hoặc tệp lịch sử…") { store.chooseHistoryImport() }.disabled(!store.supports("import_history") || !store.session.loggedIn)
    }
    if let summary = store.importSummary { Label(summary, systemImage: "checkmark.circle").font(.callout).textSelection(.enabled) }
    Text("Hỗ trợ tệp backup_zalo_….zl.zip do Zalo trên máy tính xuất ra, không giới hạn dung lượng (đã tính cho tệp trên 10 GB). Ảnh, video, tệp chỉ được chép khi bật tùy chọn ở trên. Tệp phải được xuất từ chính tài khoản đang đăng nhập. Tệp .db/.sqlite không giới hạn; tệp .json tối đa 2 GB.").font(.caption).foregroundStyle(.secondary)
   }
  case .storage:
   Section { StorageOverview(clearCache: { clearCacheConfirmation = true }) }
   if store.downloading { Section { Button("Hủy tệp đang tải") { store.send("cancel_download") }.disabled(!store.supports("cancel_download")) } }
   Section("Thư mục dữ liệu") { Text(verbatim: store.dataDirectory.path).font(.caption).textSelection(.enabled); Button("Chọn thư mục khác…") { store.chooseDataDirectory() }.disabled(store.demo); Button("Hiển thị trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory]) }; Text("Đóng ứng dụng khác đang dùng cùng thư mục trước khi chuyển.").font(.caption).foregroundStyle(.secondary) }
  case .appearance:
   Section("Màu sắc") { Picker("Chế độ", selection: $appearance) { Text("Theo hệ thống").tag("system"); Text("Sáng").tag("light"); Text("Tối").tag("dark") }; Text("Thanh công cụ, ô soạn và bảng nổi dùng Liquid Glass của macOS, tự giảm độ trong suốt theo cài đặt Trợ năng.").font(.caption).foregroundStyle(.secondary) }
   Section { ChatBackgroundPicker() } header: { Text("Hình nền cuộc trò chuyện") } footer: { Text("Áp dụng cho mọi cuộc trò chuyện trên máy này.").font(.caption).foregroundStyle(.secondary) }
   Section { MessageTextSizePicker() } header: { Text("Cỡ chữ") } footer: { Text("Áp dụng cho nội dung tin nhắn, trích dẫn và ô soạn tin.").font(.caption).foregroundStyle(.secondary) }
   Section("Khung trò chuyện") { Toggle("Hiển thị ảnh thu nhỏ", isOn: $thumbnails) }
  case .notifications:
   Section("Quyền từ macOS") { LabeledContent("Quyền thông báo", value: system.notificationStatus); Button("Yêu cầu quyền thông báo") { system.requestNotifications() } }
   Section("Thông báo trên máy") { Toggle("Thông báo tin nhắn và nhắc hẹn", isOn: $notifications); Toggle("Âm thanh thông báo", isOn: $notificationSound).disabled(!notifications); Toggle("Hiện tên và nội dung tin nhắn trong thông báo", isOn: $notificationPreview).disabled(!notifications); Toggle("Hiện số tin chưa đọc trên Dock", isOn: $dockBadge); Text("Hội thoại đã tắt thông báo hoặc đã ẩn không tạo thông báo. Khi ứng dụng đang khóa, thông báo không hiện nội dung.").font(.caption).foregroundStyle(.secondary); Text("Nếu macOS chặn thông báo, bật tùy chọn trong app không thể vượt qua quyền hệ thống.").font(.caption).foregroundStyle(.secondary) }
  case .messages:
   Section("Soạn và đọc") { Toggle("Return để gửi; Shift + Return xuống dòng", isOn: $sendWithReturn); Toggle("Nhấp đúp tin nhắn để trả lời", isOn: $doubleClickReply); Toggle("Hiển thị ảnh thu nhỏ", isOn: $thumbnails) }
   Section("Danh sách hội thoại") { Toggle("Tách Ưu tiên và Khác", isOn: $prioritySplit); Text("Bật để có hai tab Ưu tiên và Khác như Zalo, đồng bộ với điện thoại; nhấp chuột phải vào hội thoại để chuyển qua lại. Tắt để xem mọi hội thoại trong một danh sách.").font(.caption).foregroundStyle(.secondary) }
   Section("Lưu tệp nhận được") {
    LabeledContent("Thư mục lưu", value: downloadDirectory.isEmpty ? "Hỏi mỗi lần lưu" : downloadDirectory)
    HStack { Button("Chọn thư mục…") { chooseDownloadDirectory() }; if !downloadDirectory.isEmpty { Button("Luôn hỏi") { downloadDirectory = "" } } }
   }
   Section("Tin nhắn nhanh") { Button("Quản lý mẫu tin…") { store.showingQuickReplies = true }.disabled(!store.supports("upsert_quick_reply")); serverToggle("Bật tin nhắn nhanh trên tài khoản", key: "quick_message_status") }
   Section("Tải nội dung") { unavailable("Tự động tải trước media dưới 30 MB chưa được kích hoạt. Nội dung được tải khi mở hoặc lưu."); unavailable("Chuyển clipboard Excel thành ảnh cần bộ chuyển đổi bảng; hiện ô nhập nhận văn bản.") }
  case .calls:
   Section("Thiết bị") {
    devicePicker("Micrô", list: "microphones", selected: "selected_microphone", parameter: "microphone")
    devicePicker("Camera", list: "cameras", selected: "selected_camera", parameter: "camera")
    LabeledContent("Loa / tai nghe", value: "Theo thiết bị mặc định của macOS")
    Button("Làm mới thiết bị") { store.send("list_media_devices") }.disabled(!store.supports("list_media_devices"))
   }
   Section("Cuộc gọi đến") { Toggle("Thông báo khi có cuộc gọi đến lúc ứng dụng ở nền", isOn: $callNotifications); Text("Nếu thiếu micrô hoặc camera, cuộc gọi báo lỗi thay vì kết nối im lặng.").font(.caption).foregroundStyle(.secondary) }
   Section("Quyền thiết bị") { Text("macOS sẽ xin quyền micrô hoặc camera khi bạn chủ động thực hiện cuộc gọi.").font(.callout).foregroundStyle(.secondary) }
  case .utilities:
   Section("Soạn nhanh") { Toggle("Gợi ý nhãn dán khi gõ", isOn: $stickerSuggestions); Text("Khi bật, từ đơn bạn đang gõ được gửi tới Zalo để tìm nhãn dán phù hợp.").font(.caption).foregroundStyle(.secondary); Toggle("Gợi ý tên thành viên khi gõ @", isOn: $mentionSuggestions); Text("Tên được chèn dưới dạng văn bản; chưa tạo thông báo nhắc tên cho người được nhắc.").font(.caption).foregroundStyle(.secondary); Button("Mở Emoji & Ký hiệu") { NSApp.orderFrontCharacterPalette(nil) }; unavailable("Tìm GIF chưa có nguồn tích hợp được xác nhận.") }
   Section("Chụp màn hình") {
    TextField("⌘⌥ + phím để chụp", text: $captureKey).onValueChange(of: captureKey) { _, value in captureKey = String(value.lowercased().prefix(1)) }
    TextField("⌘⌥ + phím để ẩn app rồi chụp", text: $captureHiddenKey).onValueChange(of: captureHiddenKey) { _, value in captureHiddenKey = String(value.lowercased().prefix(1)) }
    Button("Chụp màn hình…") { NativeSystem.captureScreen(hideApp: false) }; Button("Ẩn app rồi chụp…") { NativeSystem.captureScreen(hideApp: true) }
    Text("Phím tắt có hiệu lực khi ứng dụng đang được chọn. macOS có thể yêu cầu quyền ghi màn hình.").font(.caption).foregroundStyle(.secondary)
   }
  }
 }
 private func accountValue(_ key: String) -> Int? { store.accountSettings?["settings"]?[key]?.number.map(Int.init) }
 private func queueSetting(_ key: String, label: String, value: Int) { pendingKey = key; pendingLabel = label; pendingValue = value }
 @ViewBuilder private func serverToggle(_ label: String, key: String) -> some View {
  if store.supports("get_account_settings") {
   Toggle(label, isOn: Binding(get: { accountValue(key) == 1 }, set: { queueSetting(key, label: label, value: $0 ? 1 : 0) }))
    .disabled(accountValue(key) == nil || store.busy.contains("set_account_setting"))
  } else { unavailable(label + ": chưa có kênh xác nhận tài khoản") }
 }
 private func serverPicker(_ label: String, key: String, values: [(Int,String)]) -> some View {
  Picker(label, selection: Binding(get: { accountValue(key) ?? values[0].0 }, set: { queueSetting(key, label: label, value: $0) })) { ForEach(values, id: \.0) { Text($0.1).tag($0.0) } }.disabled(accountValue(key) == nil || !store.supports("set_account_setting"))
 }
 private func guardToggle(_ label: String, key: String) -> some View {
  Toggle(label, isOn: Binding(get: { store.privacyGuard?[key]?.bool ?? false }, set: { value in
   var params: [String:JSONValue] = [:]; for field in ["block_typing","block_delivered","block_seen"] { params[field] = .bool(field == key ? value : store.privacyGuard?[field]?.bool ?? false) }; store.send("set_privacy_guard", parameters: params)
  })).disabled(!store.supports("set_privacy_guard") || store.privacyGuard == nil || store.busy.contains("set_privacy_guard"))
 }
 private func usage(_ label: String, key: String) -> some View { LabeledContent(label, value: store.features.usage?[key]?.number.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Chưa tính") }
 private func unavailable(_ text: String) -> some View { Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
 @ViewBuilder private func devicePicker(_ label: String, list: String, selected: String, parameter: String) -> some View {
  if case .array(let values) = store.mediaDevices?[list] {
   Picker(label, selection: Binding(get: { store.mediaDevices?[selected]?.string ?? "" }, set: { value in
    store.send("select_media_devices", parameters: ["microphone": .string(parameter == "microphone" ? value : store.mediaDevices?["selected_microphone"]?.string ?? ""), "camera": .string(parameter == "camera" ? value : store.mediaDevices?["selected_camera"]?.string ?? "")])
   })) { ForEach(values.compactMap(\.string), id: \.self) { Text($0).tag($0) } }
  } else { LabeledContent(label, value: "Thiết bị mặc định") }
 }
 private var twoFactorForm: some View {
  VStack(alignment: .leading, spacing: 18) {
   Text(accountValue("setting_2FA_status") == 1 ? "Tắt bảo mật hai lớp?" : "Bật bảo mật hai lớp?").font(.title2.bold())
   Text("Thao tác thay đổi bảo mật tài khoản Zalo. Nhập mã OTP nếu hệ thống yêu cầu; mã chỉ dùng cho yêu cầu này.").foregroundStyle(.secondary)
   SecureField("Mã OTP (nếu được yêu cầu)", text: $otp).textFieldStyle(.roundedBorder)
   HStack { Button("Hủy") { otp = ""; twoFactorSheet = false }; Spacer(); Button("Xác nhận thay đổi") { var params: [String:JSONValue] = ["enabled": .bool(accountValue("setting_2FA_status") != 1)]; if !otp.isEmpty { params["otp"] = .string(otp) }; store.send("set_two_factor", parameters: params); otp = ""; twoFactorSheet = false }.buttonStyle(.borderedProminent) }
  }.padding(26).frame(width: 480)
 }
 private func applyRequestedPage() {
  guard let key = store.requestedSettingsPage, let target = SettingsPage.allCases.first(where: { $0.key == key }) else { return }
  page = target; store.requestedSettingsPage = nil
 }
 private func chooseDownloadDirectory() {
  let panel = NSOpenPanel(); panel.title = "Chọn thư mục lưu tệp nhận được"; panel.prompt = "Dùng thư mục này"
  panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
  panel.begin { response in
   guard response == .OK, let url = panel.url else { return }
   Task { @MainActor in downloadDirectory = url.path }
  }
 }
 private func refreshPage() {
  if [.privacy,.security,.messages].contains(page) && store.supports("get_account_settings") { store.send("get_account_settings") }
  if page == .privacy && store.supports("get_privacy_guard") { store.send("get_privacy_guard") }
  if page == .storage && store.supports("data_usage") { store.send("data_usage") }
  if page == .calls && store.supports("list_media_devices") { store.send("list_media_devices") }
 }
}

/// Rounded colour tile with a white symbol, as used across macOS settings.
struct SettingsIconTile: View {
 let icon: String
 let tint: Color
 var size: CGFloat = 22
 var body: some View {
  Image(systemName: icon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
   .frame(width: size, height: size)
   .background(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
 }
}

/// Swatches for the transcript background, including a picture chosen by the person.
struct ChatBackgroundPicker: View {
 @AppStorage("nativeChatBackground") private var choice = "none"
 @AppStorage("nativeChatBackgroundImage") private var imagePath = ""
 @AppStorage("nativeChatBackgroundDim") private var dim = 0.15
 @State private var failure: String?
 private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 12)]
 var body: some View {
  VStack(alignment: .leading, spacing: 12) {
   LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
    swatch("none", "Mặc định") { Color(nsColor: .textBackgroundColor) }
    ForEach(ChatBackground.presets, id: \.id) { preset in
     swatch("preset:" + preset.id, preset.title) { LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    }
    swatch("avatar", "Ảnh đại diện mờ") {
     LinearGradient(colors: [.pink.opacity(0.35), .blue.opacity(0.35)], startPoint: .top, endPoint: .bottom).overlay { Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.white) }
    }
    swatch("image", "Ảnh của bạn") {
     Group {
      if !imagePath.isEmpty, let image = NSImage(contentsOfFile: imagePath) { Image(nsImage: image).resizable().scaledToFill() }
      else { Color.primary.opacity(0.06).overlay { Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary) } }
     }
    }
   }
   HStack {
    Button("Chọn ảnh…") { chooseImage() }
    if choice == "image" {
     Text("Làm dịu ảnh").foregroundStyle(.secondary)
     Slider(value: $dim, in: 0...0.6).frame(maxWidth: 180)
    }
   }
   if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
  }.padding(.vertical, 4)
 }
 private func swatch<Content: View>(_ id: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
  Button {
   if id == "image" && imagePath.isEmpty { chooseImage() } else { choice = id }
  } label: {
   VStack(spacing: 5) {
    content().frame(height: 58).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
     .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(choice == id ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: choice == id ? 3 : 1) }
    Text(title).font(.caption).foregroundStyle(choice == id ? Color.primary : Color.secondary).lineLimit(1)
   }.contentShape(Rectangle())
  }.buttonStyle(.plain).accessibilityAddTraits(choice == id ? .isSelected : [])
 }
 private func chooseImage() {
  let panel = NSOpenPanel(); panel.title = "Chọn ảnh làm hình nền"; panel.prompt = "Dùng ảnh này"
  panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
  panel.begin { response in
   guard response == .OK, let url = panel.url else { return }
   Task { @MainActor in
    do {
     let saved = try await Task.detached { try ChatBackground.importImage(from: url) }.value
     imagePath = saved.path; choice = "image"; failure = nil
    } catch { failure = "Không đọc được ảnh đã chọn. Hãy thử ảnh JPEG, PNG hoặc HEIC khác." }
   }
  }
 }
}

/// Zalo-style data overview: total, a bar against the disk, and each kind with what it holds.
struct StorageOverview: View {
 @EnvironmentObject var store: AppStore
 let clearCache: () -> Void
 @State private var disk: (free: Int64, total: Int64)?
 @State private var updated: Date?

 private func bytes(_ key: String) -> Int64? { store.features.usage?[key]?.number.map { Int64($0) } }
 private func text(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Đang tính…" }

 var body: some View {
  VStack(alignment: .leading, spacing: 14) {
   Text("Dữ liệu Zalolite").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
   Text(text(bytes("total_bytes"))).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.tint)
   if let disk, disk.total > 0 {
    let app = Double(bytes("total_bytes") ?? 0), used = Double(disk.total - disk.free), total = Double(disk.total)
    GeometryReader { proxy in
     HStack(spacing: 0) {
      Rectangle().fill(Color.accentColor).frame(width: max(3, proxy.size.width * app / total))
      Rectangle().fill(Color.cyan.opacity(0.8)).frame(width: max(0, proxy.size.width * (used - app) / total))
      Rectangle().fill(Color.primary.opacity(0.12))
     }.clipShape(Capsule())
    }.frame(height: 10)
    HStack(spacing: 14) {
     legend(.accentColor, "Zalolite"); legend(.cyan.opacity(0.8), "Ứng dụng khác")
     Spacer()
     Text("\(ByteCountFormatter.string(fromByteCount: disk.free, countStyle: .file)) trống").font(.system(size: 12)).foregroundStyle(.secondary)
    }
   }
   VStack(spacing: 0) {
    row("photo.on.rectangle", "Tệp đã tải về", "Ảnh, video, tệp nhập từ bản sao lưu Zalo và những tệp bạn đã mở hoặc tải. Ảnh mới trong cuộc trò chuyện được xem trực tiếp từ Zalo.", bytes("media_bytes")) {
     Button { NSWorkspace.shared.activateFileViewerSelecting([store.previewDirectory]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Mở thư mục")
    }
    Divider()
    row("internaldrive", "Bộ nhớ đệm", "Nhãn dán và dữ liệu tạm giúp mở nhanh hơn; dọn đi thì sẽ được tải lại khi cần.", bytes("cache_bytes")) {
     Button(action: clearCache) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.red)
      .disabled(!store.supports("clear_cache") || store.busy.contains("clear_cache")).help("Dọn bộ nhớ đệm")
    }
    Divider()
    row("cylinder.split.1x2", "Dữ liệu hệ thống", "Lịch sử tin nhắn của tài khoản đang dùng và dữ liệu cần để ứng dụng chạy.", bytes("system_bytes")) { EmptyView() }
    if (bytes("other_accounts_bytes") ?? 0) > 0 {
     Divider()
     row("person.2", "Tài khoản khác", "Lịch sử và phiên của các tài khoản khác đã đăng nhập trên máy này.", bytes("other_accounts_bytes")) { EmptyView() }
    }
   }
   HStack(spacing: 4) {
    if let updated { Text("Cập nhật lúc \(updated.formatted(date: .omitted, time: .shortened)).") }
    Button("Làm mới") { refresh() }.buttonStyle(.link).disabled(!store.supports("data_usage"))
   }.font(.system(size: 12)).foregroundStyle(.secondary)
   Text("Zalo trên máy tính tải và giữ lại mọi ảnh, video, tệp đã xem nên thường chiếm nhiều GB; Zalolite lưu tin nhắn, tệp bạn tải về và media nhập từ bản sao lưu khi bạn chọn.")
    .font(.caption).foregroundStyle(.secondary)
  }
  .padding(.vertical, 6)
  .onAppear { refresh() }
  .onValueChange(of: store.features.usage) { _, _ in updated = Date() }
 }

 private func refresh() {
  if store.supports("data_usage") { store.send("data_usage") }
  let url = store.dataDirectory
  Task {
   let values = await Task.detached { try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) }.value
   if let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity { disk = (free, Int64(total)) }
  }
 }

 private func legend(_ color: Color, _ title: String) -> some View {
  HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10); Text(title).font(.system(size: 12)) }
 }

 private func row<Action: View>(_ icon: String, _ title: String, _ detail: String, _ value: Int64?, @ViewBuilder action: () -> Action) -> some View {
  HStack(alignment: .center, spacing: 12) {
   Image(systemName: icon).font(.system(size: 18)).frame(width: 28).foregroundStyle(.secondary)
   VStack(alignment: .leading, spacing: 2) {
    Text(title).font(.system(size: 13.5, weight: .semibold))
    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
   }
   Spacer(minLength: 8)
   Text(text(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
   action().frame(width: 22)
  }.padding(.vertical, 9)
 }
}
