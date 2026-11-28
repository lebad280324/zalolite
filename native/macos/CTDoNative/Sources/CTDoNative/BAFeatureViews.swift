import AppKit
import SwiftUI
import NativeBridge

struct FeatureSectionSidebar: View {
 @EnvironmentObject var store: AppStore
 var body: some View {
  VStack(alignment: .leading, spacing: 14) {
   Button { store.workspaceSection = .messages } label: { Label("Tin nhắn", systemImage: "chevron.left").font(.callout.weight(.medium)) }
    .buttonStyle(.plain).foregroundStyle(.tint).help("Quay lại danh sách tin nhắn")
   Text(store.workspaceSection == .contacts ? "Danh bạ" : "Đã lưu").font(.title2.bold())
   if store.workspaceSection == .contacts {
    ForEach(ContactSection.allCases) { section in
     Button { store.contactSection = section } label: { HStack { Text(section.rawValue); Spacer(); if section == .invitations, !store.features.friendInvitations.isEmpty { Text("\(store.features.friendInvitations.count)").font(.caption.weight(.semibold)).monospacedDigit() } }.padding(.horizontal, 12).padding(.vertical, 9).foregroundStyle(section == store.contactSection ? Color.white : Color(nsColor: .labelColor)).background(section == store.contactSection ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
    }
    Button("Tìm bạn mới…") { store.showingContactLookup = true }.disabled(!store.supports("lookup_phone"))
   } else {
    Label("Đánh dấu và ghim trên máy", systemImage: "bookmark")
    Label("Nhắc hẹn riêng", systemImage: "bell.badge")
    Button("Tin nhắn nhanh…") { store.showingQuickReplies = true }
   }
   Spacer()
   Text(verbatim: store.session.name).font(.headline)
   Text(verbatim: store.connection).font(.caption).foregroundStyle(.secondary)
  }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
 }
}

struct ContactsWorkspace: View {
 @EnvironmentObject var store: AppStore
 @State var query = ""
 @State var ascending = true
 var rows: [FeatureRow] {
  if store.contactSection == .invitations {
   return store.features.friendInvitations.filter { query.isEmpty || $0.string("name").localizedStandardContains(query) }
  }
  return (store.contactSection == .groups ? store.features.groups : store.contactSection == .invitations ? store.features.friendInvitations : store.contactSection == .groupInvitations ? store.features.groupInvitations : store.contactSection == .blocked ? store.features.blockedContacts : store.features.contacts)
   .filter { query.isEmpty || $0.string("name").localizedStandardContains(query) }
   .sorted { ($0.string("name").localizedStandardCompare($1.string("name")) == .orderedAscending) == ascending }
 }
 /// Friends are grouped by first letter; other lists stay flat.
 var sections: [(String, [FeatureRow])] {
  guard store.contactSection == .friends else { return [("", rows)] }
  var order: [String] = []; var groups: [String: [FeatureRow]] = [:]
  for row in rows { let letter = ComposerAssistText.sectionLetter(row.string("name")); if groups[letter] == nil { order.append(letter) }; groups[letter, default: []].append(row) }
  return order.map { ($0, groups[$0] ?? []) }
 }
 /// The list command behind the sections that can arrive incomplete.
 var sectionCommand: String? {
  switch store.contactSection {
  case .invitations: return "list_friend_requests"
  case .groupInvitations: return "list_group_invitations"
  case .blocked: return "list_blocked_contacts"
  default: return nil
  }
 }
 var listBusy: Bool { !store.busy.isDisjoint(with: ["list_contacts", "list_groups", "list_friend_requests", "list_group_invitations", "list_blocked_contacts"]) }
 var body: some View {
  VStack(alignment: .leading, spacing: 18) {
   HStack { Text(store.contactSection.rawValue).font(.title.bold()); Spacer(); if store.supports("create_group") {Button("Tạo nhóm…"){store.showingCreateGroup=true}}; Button("Làm mới", systemImage: "arrow.clockwise") { reload(force: true) } }
   Group {
    HStack { TextField(store.contactSection == .groups ? "Tìm nhóm" : "Tìm bạn theo tên", text: $query).textFieldStyle(.roundedBorder); Picker("Sắp xếp", selection: $ascending) { Text("A–Z").tag(true); Text("Z–A").tag(false) }.frame(width: 140); Text("\(rows.count) mục").foregroundStyle(.secondary) }
    if let command = sectionCommand, store.features.partialLists.contains(command) {
     Label("Danh sách này mới tải trang đầu, có thể chưa đầy đủ.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
    }
    List { ForEach(sections, id: \.0) { letter, items in Section(letter) { ForEach(items) { row in
     HStack(spacing: 12) {
      AvatarView(name: row.string("name"), url: row.string("avatar"), size: 42, group: store.contactSection == .groups)
      VStack(alignment: .leading, spacing: 4) {
       Text(verbatim: row.string("name")).font(.headline).lineLimit(2)
       if row.number("member_count") > 0 { Text("\(Int(row.number("member_count"))) thành viên").font(.caption).foregroundStyle(.secondary) }
       if store.contactSection == .invitations { FriendRequestDetail(row: row) }
      }
      Spacer()
      if store.contactSection == .invitations {
       Button("Chấp nhận"){store.send("accept_friend",parameters:["user_id":.string(row.id)])}.fixedSize()
        .disabled(store.busy.contains("accept_friend"))
       Button("Từ chối"){store.send("reject_friend",parameters:["user_id":.string(row.id)])}.fixedSize()
        .disabled(store.busy.contains("reject_friend"))
      }
      if store.contactSection == .groupInvitations {Button("Tham gia"){store.send("join_group_invitation",parameters:["thread_id":.string(row.id)])}}
      if store.contactSection == .blocked {Button("Bỏ chặn"){store.send("set_contact_blocked",parameters:["user_id":.string(row.id),"blocked":.bool(false)])}}
      Button("Nhắn tin") { store.openContact(row) }.fixedSize()
       .disabled(!store.supports("open_contact") && !store.threads.contains { $0.id == row.id })
      if store.contactSection == .friends && store.supports("check_friend") { Button("Kết nối") { store.send("check_friend", parameters: ["user_id": .string(row.id)]) } }
     }.padding(.vertical, 7)
      .contextMenu { contactMenu(row) }
    } } } }.listStyle(.inset).scrollContentBackground(.hidden)
     .overlay {
      if rows.isEmpty {
       if listBusy { ProgressView("Đang tải danh sách…") }
       else if !query.isEmpty { EmptyState("Không có kết quả", systemImage: "magnifyingglass", description: Text("Thử từ khóa khác.")) }
       else { EmptyState("Danh sách trống", systemImage: "person.2", description: Text("Nhấn Làm mới để tải lại từ Zalo.")) }
      }
     }
   }
  }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity).background { WorkspaceBackdrop() }
   .onValueChange(of:store.contactSection){_,_ in reload()}.onAppear{reload()}
 }
 @ViewBuilder func contactMenu(_ row: FeatureRow) -> some View {
  Button("Nhắn tin", systemImage: "bubble.left") { store.openContact(row) }
  Button("Sao chép tên", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.string("name"), forType: .string) }
  if store.contactSection == .friends {
   if let thread = store.threads.first(where: { $0.id == row.id && !$0.isGroup }), store.supports("update_alias") { Button("Đặt tên gợi nhớ…", systemImage: "pencil") { store.aliasThread = thread } }
   if store.supports("create_group") { Button("Tạo nhóm với người này…", systemImage: "person.3") { store.groupSeed = row } }
   if store.supports("add_group_members") { Button("Thêm vào nhóm…", systemImage: "person.crop.circle.badge.plus") { store.addToGroupUser = row } }
   if store.supports("set_contact_blocked") { Divider(); Button("Chặn…", systemImage: "hand.raised", role: .destructive) { store.blockCandidate = row } }
  }
  if store.contactSection == .groups, let thread = store.threads.first(where: { $0.id == row.id && $0.isGroup }), store.supports("add_group_members") {
   Button("Thêm thành viên…", systemImage: "person.badge.plus") { store.groupToInvite = thread }
  }
 }
 func reload(force: Bool = false){store.workspaceSection = .contacts;store.loadContactLists(force: force);let command = store.contactSection == .invitations ? "list_friend_requests" : store.contactSection == .groupInvitations ? "list_group_invitations" : store.contactSection == .blocked ? "list_blocked_contacts" : "";if !command.isEmpty && store.supports(command) && !store.busy.contains(command){store.send(command)}}
}

struct SavedWorkspace: View {
 @EnvironmentObject var store: AppStore
 @State var tab = "bookmarks"
 @State var query = ""
 var body: some View {
  VStack(alignment: .leading, spacing: 18) {
   Text("Nội dung đã lưu").font(.title.bold())
   Text("Lưu riêng trên máy cho tài khoản này.").foregroundStyle(.secondary)
   Picker("Nội dung", selection: $tab) { Text("Đánh dấu").tag("bookmarks"); Text("Ghim trên máy").tag("pinned_messages"); Text("Nhắc hẹn").tag("reminders"); Text("Hội thoại ẩn").tag("hidden") }.pickerStyle(.segmented).labelsHidden()
   TextField(tab == "hidden" ? "Tìm hội thoại ẩn" : "Tìm nội dung đã lưu", text: $query).textFieldStyle(.roundedBorder)
   if tab == "hidden" { hiddenList } else {
   List(store.features.rows(tab).filter { query.isEmpty || $0.string("text", "title").localizedStandardContains(query) }) { row in
    HStack(alignment: .top) {
     VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: row.string("text", "title")).textSelection(.enabled)
      if tab == "reminders" { Text(bridgeDate(row.number("remind_at")), format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary) }
      else { Text(verbatim: row.string("sender")).font(.caption).foregroundStyle(.secondary) }
     }
     Spacer()
     if let thread = store.threads.first(where: { $0.id == row.string("thread_id") }) {
      if tab != "reminders" && !row.string("message_id").isEmpty { Button("Đến tin gốc") { store.jump(toThread: thread.id, messageID: row.string("message_id")) } }
      else { Button("Mở hội thoại") { store.selectThread(thread.id) } }
      if tab == "bookmarks" { Button { store.featureThread("bookmark_message", thread: thread, values: ["message_id": .string(row.string("message_id")), "bookmarked": .bool(false)]) } label: { Image(systemName: "star.slash") }.help("Bỏ đánh dấu") }
      if tab == "pinned_messages" { Button { store.featureThread("pin_message_local", thread: thread, values: ["message_id": .string(row.string("message_id")), "pinned": .bool(false)]) } label: { Image(systemName: "pin.slash") }.help("Bỏ ghim trên máy") }
     }
     if tab == "reminders" { Button(role: .destructive) { store.send("delete_reminder", parameters: ["id": .string(row.id)]) } label: { Image(systemName: "trash") } }
    }.padding(.vertical, 8)
   }.listStyle(.inset).scrollContentBackground(.hidden)
    .overlay { if store.features.rows(tab).isEmpty { EmptyState("Chưa có nội dung", systemImage: "bookmark", description: Text("Dùng menu của tin nhắn hoặc hội thoại để lưu vào đây.")) } }
   }
  }.padding(26).background { WorkspaceBackdrop() }.onAppear { store.reloadWorkspaceFeatures() }
 }
 /// Hidden conversations stay behind macOS authentication for the current session.
 @ViewBuilder var hiddenList: some View {
  if !store.hiddenUnlocked {
   VStack(spacing: 14) {
    Image(systemName: "eye.slash").font(.system(size: 38)).foregroundStyle(.tint)
    Text("Xác thực bằng tài khoản macOS để xem hội thoại đã ẩn.").foregroundStyle(.secondary)
    Button("Xác thực") { NativeSystem.unlock { store.hiddenUnlocked = $0 } }.buttonStyle(.borderedProminent)
    Text("Đây là lớp bảo vệ trên máy này, không phải mã PIN ẩn trò chuyện của Zalo.").font(.caption).foregroundStyle(.secondary)
   }.frame(maxWidth: .infinity, maxHeight: .infinity)
  } else {
   List(store.hiddenThreads.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { thread in
    HStack(spacing: 12) {
     ThreadAvatar(thread: thread, size: 36)
     Text(verbatim: thread.name).font(.headline)
     Spacer()
     Button("Hiện lại") { store.featureThread("hide_thread", thread: thread, values: ["hide": .bool(false)]) }.disabled(store.busy.contains("hide_thread"))
    }.padding(.vertical, 6)
   }.listStyle(.inset).scrollContentBackground(.hidden)
    .overlay { if store.hiddenThreads.isEmpty { EmptyState("Không có hội thoại ẩn", systemImage: "eye", description: Text("Hội thoại bạn ẩn từ menu sẽ nằm ở đây.")) } }
  }
 }
}

struct ThreadManagementMenu: View {
 @EnvironmentObject var store: AppStore
 let thread: ThreadSnapshot
 @ObservedObject private var bridge = AIBridgeSettings.shared
 var body: some View {
  if bridge.enabled && !store.demo { Button(bridge.isShared(thread) ? "Ngừng chia sẻ với trợ lý AI" : "Chia sẻ với trợ lý AI", systemImage: "sparkles") { bridge.toggle(thread) } }
  if store.supports("set_thread_priority") { let priority = store.isPriority(thread); Button(priority ? "Chuyển sang mục Khác" : "Đưa vào Ưu tiên", systemImage: priority ? "tray" : "star") { store.featureThread("set_thread_priority", thread: thread, values: ["priority": .bool(!priority)]) } }
  if !thread.isGroup && store.supports("update_alias") { Button("Đặt tên gợi nhớ…", systemImage: "pencil") { store.aliasThread = thread } }
  if store.supports("set_thread_category") { Button("Phân loại…", systemImage: "tag") { store.threadOptions = thread } }
  if store.supports("mark_thread_unread") { Button(thread.hasUnread ? "Đánh dấu đã đọc" : "Đánh dấu chưa đọc", systemImage: "circle.badge") { store.featureThread("mark_thread_unread", thread: thread, values: ["unread": .bool(!thread.hasUnread)]) } }
  if !thread.isGroup {
   if store.supports("add_group_members") { Button("Thêm vào nhóm…", systemImage: "person.crop.circle.badge.plus") { store.addToGroupUser = store.contactRow(for: thread) } }
   if store.supports("create_group") { Button("Tạo nhóm với người này…", systemImage: "person.3") { store.groupSeed = store.contactRow(for: thread) } }
  } else if store.supports("add_group_members") { Button("Thêm thành viên…", systemImage: "person.badge.plus") { store.groupToInvite = thread } }
  if store.supports("upsert_reminder") { Button("Tạo nhắc hẹn…", systemImage: "bell.badge") { store.reminderThread = thread } }
  if store.supports("hide_thread") { Button("Ẩn hội thoại", systemImage: "eye.slash") { store.featureThread("hide_thread", thread: thread, values: ["hide": .bool(true)]) } }
  if store.supports("delete_thread") { Divider(); Button("Xóa hội thoại…", systemImage: "trash", role: .destructive) { store.destructiveThread = thread } }
 }
}

/// Local category for a conversation (kept on this Mac only).
struct ThreadOptionsView: View {
 @EnvironmentObject var store: AppStore
 @Environment(\.dismiss) var dismiss
 let thread: ThreadSnapshot
 @State var category = ""
 var body: some View {
  VStack(alignment: .leading, spacing: 16) {
   Text("Phân loại hội thoại").font(.title3.bold())
   Text("Nhóm \(thread.name) vào một mục để lọc nhanh. Phân loại chỉ lưu trên máy này.").font(.callout).foregroundStyle(.secondary)
   TextField("Ví dụ: Công việc, Gia đình", text: $category).textFieldStyle(.roundedBorder)
   HStack { Spacer(); Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
    Button("Lưu") { store.featureThread("set_thread_category", thread: thread, values: ["category": .string(category)]); dismiss() }
     .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
  }.padding(22).frame(width: 400).onAppear { category = store.features.thread(thread.id)?.string("category") ?? "" }
 }
}

/// Zalo's "Đặt tên gợi nhớ": one nickname, saved on Zalo and shown only to this account.
struct AliasEditor: View {
 @EnvironmentObject var store: AppStore
 @Environment(\.dismiss) var dismiss
 let thread: ThreadSnapshot
 @State var alias = ""
 private var zaloName: String { store.originalNames[thread.id] ?? thread.name }
 var body: some View {
  VStack(spacing: 14) {
   Text("Đặt tên gợi nhớ").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
   AvatarView(name: zaloName, url: thread.avatar, size: 72)
   (Text("Hãy đặt cho ") + Text(verbatim: zaloName).bold() + Text(" một cái tên dễ nhớ.\nLưu ý: Tên gợi nhớ sẽ chỉ hiển thị riêng với bạn."))
    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
   TextField("Tên gợi nhớ", text: $alias).textFieldStyle(.roundedBorder).font(.system(size: 14))
   HStack { Spacer(); Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
    Button("Xác nhận") {
     let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
     // An empty name, or the person's own Zalo name, removes the nickname.
     store.featureThread("update_alias", thread: thread, values: ["alias": .string(value == zaloName ? "" : value)])
     dismiss()
    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
  }
  .padding(22).frame(width: 380)
  .onAppear { alias = store.aliases[thread.id] ?? store.features.thread(thread.id)?.string("alias") ?? thread.name }
 }
}

struct ReminderEditor: View {
 @EnvironmentObject var store: AppStore
 @Environment(\.dismiss) var dismiss
 let thread: ThreadSnapshot
 @State var title = ""
 @State var date = Date().addingTimeInterval(3600)
 var body: some View {
  VStack(alignment: .leading, spacing: 20) {
   Text("Nhắc hẹn riêng").font(.title2.bold()); Text("Nhắc hẹn không tự gửi tin nhắn.").foregroundStyle(.secondary)
   TextField("Việc cần nhớ", text: $title).textFieldStyle(.roundedBorder); DatePicker("Nhắc tôi lúc", selection: $date, in: Date()...)
   HStack { Button("Hủy") { dismiss() }; Spacer(); Button("Tạo nhắc hẹn") { store.send("upsert_reminder", parameters: ["id": .string(UUID().uuidString), "thread_id": .string(thread.id), "title": .string(title), "remind_at": .number(date.timeIntervalSince1970.rounded(.down)), "completed": .bool(false)]); dismiss() }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
  }.padding(26).frame(width: 450)
 }
}

struct QuickRepliesView: View {
 @EnvironmentObject var store: AppStore
 @Environment(\.dismiss) var dismiss
 @State var shortcut = ""
 @State var text = ""
 var body: some View {
  VStack(alignment: .leading, spacing: 16) {
   HStack { Text("Tin nhắn nhanh").font(.title2.bold()); Spacer(); Button("Đóng") { dismiss() } }
   Text("Chèn vào bản nháp; chỉ gửi khi bạn nhấn Gửi.").foregroundStyle(.secondary)
   List(store.features.rows("quick_replies")) { row in HStack { VStack(alignment: .leading) { Text("/" + row.string("shortcut")).bold(); Text(verbatim: row.string("text")).lineLimit(3) }; Spacer(); Button("Chèn") { store.draft += (store.draft.isEmpty ? "" : "\n") + row.string("text"); dismiss() }.disabled(store.selectedThread == nil); Button(role: .destructive) { store.send("delete_quick_reply", parameters: ["id": .string(row.id)]) } label: { Image(systemName: "trash") } } }
   Divider(); TextField("Phím gợi nhớ", text: $shortcut).textFieldStyle(.roundedBorder); TextField("Nội dung mẫu", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
   Button("Lưu mẫu mới") { store.send("upsert_quick_reply", parameters: ["id": .string(UUID().uuidString), "shortcut": .string(shortcut), "text": .string(text)]); shortcut = ""; text = "" }.disabled(shortcut.isEmpty || text.isEmpty || !store.supports("upsert_quick_reply"))
  }.padding(26).frame(width: 550, height: 510).onAppear { store.reloadWorkspaceFeatures() }
 }
}

struct MessageDetailsView: View {
 @Environment(\.dismiss) var dismiss
 let message: MessageSnapshot
 var body: some View {
  VStack(alignment: .leading, spacing: 18) {
   HStack { Text("Chi tiết tin nhắn").font(.title2.bold()); Spacer(); Button("Đóng") { dismiss() } }
   Form { LabeledContent("Mã tin", value: message.id); LabeledContent("Người gửi", value: message.senderName); LabeledContent("Thời gian", value: message.date.formatted(date: .abbreviated, time: .standard)); LabeledContent("Loại", value: message.messageType) }.textSelection(.enabled)
   ScrollView { Text(verbatim: message.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
  }.padding(26).frame(width: 530, height: 390)
 }
}

/// The note and date a sender attached to a friend request, as Zalo shows them.
struct FriendRequestDetail: View {
 let row: FeatureRow
 var body: some View {
  let note = row.string("message")
  let time = row.number("time")
  VStack(alignment: .leading, spacing: 2) {
   if !note.isEmpty { Text(verbatim: note).font(.callout).lineLimit(3).textSelection(.enabled) }
   if time > 0 {
    Text(Date(timeIntervalSince1970: time / 1000), format: .dateTime.day().month().year().hour().minute())
     .font(.caption).foregroundStyle(.secondary)
   }
  }
 }
}

/// A row above the conversation list while friend requests wait for an answer.
struct FriendRequestsBanner: View {
 @EnvironmentObject var store: AppStore
 var body: some View {
  let count = store.features.friendInvitations.count
  if count > 0 && store.supports("list_friend_requests") {
   Button { store.showFriendRequests() } label: {
    HStack(spacing: 8) {
     Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.tint)
     Text("\(count) lời mời kết bạn").font(.callout.weight(.medium))
     Spacer(minLength: 0)
     Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
    }.padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
   }.buttonStyle(.plain).padding(.bottom, 4).help("Mở danh sách lời mời kết bạn")
  }
 }
}
