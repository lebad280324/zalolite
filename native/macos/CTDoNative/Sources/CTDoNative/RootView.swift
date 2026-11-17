import SwiftUI
import AppKit
import NativeBridge

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var sidebarWidth: CGFloat = 300
    @State private var searchOpen = false
    @State private var globalQuery = ""
    @State private var viewerURL: URL?
    @State private var searchFocusRequest = UUID()
    @StateObject private var recentSearches = RecentSearchHistory()
    @AppStorage("nativePrioritySplit") private var prioritySplit = true
    @State private var threadMenu: ThreadMenuTarget?
    @State private var hoveredThread = HoverBox()
    @State private var rootFrame = FrameBox()
    @StateObject private var threadMenuMonitor = MessageMenuMonitor()

    var body: some View {
        Group {
            if store.session.loggedIn { workspace }
            else { LoginView() }
        }
        // The wallpaper stays when no conversation is open, e.g. right after launch.
        .background { if store.session.loggedIn {ChatBackgroundView(thread:store.selectedThread)} else {WorkspaceBackdrop()} }
        .background(NativeWindowChrome { radius in if abs(store.windowCornerRadius - radius) > 0.5 { store.windowCornerRadius = radius } })
        .onAppear { let open = openWindow; store.openMainWindow = { open(id: "main") } }
        .onChange(of: store.session.uin, initial: true) { _, account in
            recentSearches.activate(account: account, persistent: !store.demo)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .accessibilityHidden(store.isLocked)
        .allowsHitTesting(!store.isLocked)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(verbatim: error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 10)
                    Button { store.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Đóng thông báo")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .confirmationDialog("Đăng xuất tài khoản?", isPresented: $store.showingLogoutConfirmation, titleVisibility: .visible) {
            Button("Đăng xuất", role: .destructive) { store.send("logout") }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Bạn cần quét mã QR để đăng nhập lại. Lịch sử đã lưu vẫn được giữ trên máy.") }
        .alert("Sử dụng thư mục dữ liệu này?", isPresented: $store.showingDataFolderConfirmation) {
            Button("Hủy", role: .cancel) { store.proposedDataDirectory = nil }
            Button("Sử dụng thư mục") { store.applyDataDirectory() }
        } message: {
            Text("Hãy đóng bản Zalolite đang sử dụng thư mục này trước khi tiếp tục. Ứng dụng sẽ mở lại với dữ liệu trong thư mục đã chọn.")
        }
        .sheet(isPresented: $store.showingStickers) { StickerPickerView() }
        .sheet(isPresented: $store.showingForward) { ForwardMessageView() }
        .sheet(isPresented: $store.showingScheduled) { ScheduledMessagesView() }
        .sheet(isPresented: $store.showingContactLookup) { ContactLookupView() }
        .sheet(item: $store.threadOptions) { ThreadOptionsView(thread: $0) }
        .sheet(item: $store.aliasThread) { AliasEditor(thread: $0) }
        .sheet(item: $store.reminderThread) { ReminderEditor(thread: $0) }
        .sheet(item: $store.messageDetails) { MessageDetailsCard(message: $0) }
        .sheet(isPresented: $store.showingQuickReplies) { QuickRepliesView() }
        .sheet(isPresented: $store.showingCreateGroup) { GroupEditor() }
        .sheet(item: $store.groupToInvite) {GroupEditor(thread:$0)}
        .sheet(item: $store.groupSeed) { GroupEditor(preselected: $0.id) }
        .sheet(item: $store.addToGroupUser) { AddToGroupView(user: $0) }
        .sheet(isPresented: $store.showingHistorySearch) { HistorySearchView() }
        .sheet(isPresented: $store.showingAccountInfo) { AccountInfoView() }
        .alert("Chặn \(store.blockCandidate?.string("name") ?? "người này")?", isPresented: Binding(get: { store.blockCandidate != nil }, set: { if !$0 { store.blockCandidate = nil } })) {
            Button("Hủy", role: .cancel) { store.blockCandidate = nil }
            Button("Chặn", role: .destructive) { store.confirmBlock() }
        } message: { Text("Người bị chặn không thể nhắn tin hoặc gọi cho bạn. Thao tác được gửi tới Zalo; bạn có thể bỏ chặn trong Danh bạ > Danh sách chặn.") }
        .overlay(alignment: .bottomLeading) { StatusPill().padding(18) }
        .onReceive(NotificationCenter.default.publisher(for: .snapshotOpenSearch)) { note in
            if store.demo, let query = note.object as? String { searchOpen = true; globalQuery = query }
        }
        .alert("Xóa hội thoại ở phía tài khoản này?", isPresented: Binding(get: { store.destructiveThread != nil }, set: { if !$0 { store.destructiveThread = nil } })) {
            Button("Hủy", role: .cancel) { store.destructiveThread = nil }
            Button("Xóa hội thoại", role: .destructive) {
                if let thread = store.destructiveThread { store.featureThread("delete_thread", thread: thread, values: ["confirmed": .bool(true)]) }
                store.destructiveThread = nil
            }
        } message: { Text("Hãy kiểm tra bản sao lưu trước khi xóa. Thao tác này được gửi đến Zalo và có thể làm mất lịch sử truy cập từ hội thoại.") }
        .background { GeometryReader { proxy in Color.clear.onAppear { rootFrame.value = proxy.frame(in: .global) }
            .onChange(of: proxy.frame(in: .global)) { _, frame in rootFrame.value = frame } } }
        .overlay(alignment: .topLeading) { threadMenuOverlay }
        .animation(reducedMotion ? nil : .snappy(duration: 0.18), value: threadMenu?.id)
        .onAppear {
            threadMenuMonitor.install(hovered: { [hoveredThread] in hoveredThread.id }) { id, location in
                guard let thread = store.threads.first(where: { $0.id == id }) else { return }
                // AppKit reports window points from the bottom; SwiftUI frames are measured from the top.
                let height = NSApp.keyWindow?.contentView?.bounds.height ?? 0
                threadMenu = ThreadMenuTarget(thread: thread, point: CGPoint(x: location.x - rootFrame.value.minX,
                                                                              y: height - location.y - rootFrame.value.minY))
            }
        }
        .onDisappear { threadMenuMonitor.remove() }
        .onReceive(NotificationCenter.default.publisher(for: .snapshotOpenThreadMenu)) { _ in
            if store.demo, let thread = store.filteredThreads.first { threadMenu = ThreadMenuTarget(thread: thread, point: CGPoint(x: 180, y: 150)) }
        }
        .overlay { if let viewerURL { ImageViewerOverlay(url: viewerURL) { self.viewerURL = nil } } }
        .onReceive(NotificationCenter.default.publisher(for: .openImageViewer)) { note in viewerURL = note.object as? URL }
        .onReceive(NotificationCenter.default.publisher(for: .replaceImageViewer)) { note in
            if viewerURL != nil, let url = note.object as? URL { viewerURL = url }
        }
        .overlay { if store.isLocked { LockedWorkspace() } }
        // A new reading size changes every row's height.
        .onReceive(NotificationCenter.default.publisher(for: .messageTextSizeChanged)) { _ in store.transcript.presentationVersion += 1 }
        .overlay(alignment: .top) { CallOverlayView().padding(.top, 58) }
    }

    @ViewBuilder private var threadMenuOverlay: some View {
        if let target = threadMenu {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { threadMenu = nil }
                    Button("") { threadMenu = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                    ThreadActionMenu(thread: target.thread) { threadMenu = nil }
                        .fixedSize()
                        .offset(x: max(8, min(target.point.x + 2, proxy.size.width - 260)),
                                y: max(8, min(target.point.y + 2, proxy.size.height - 470)))
                        .transition(.scale(scale: 0.86, anchor: .topLeading).combined(with: .opacity))
                }
            }
        }
    }

    private var workspace: some View {
        WorkspaceColumnsLayout(sidebarWidth:sidebarWidth) {
            VStack(spacing: 0) {
                if searchOpen { SidebarSearchResults(query: globalQuery, recentSearches: recentSearches, selectRecent: { query in
                    globalQuery = query; searchFocusRequest = UUID()
                }) { closeSearch() } }
                else if store.workspaceSection == .messages { threadList } else { FeatureSectionSidebar() }
            }
            .frame(maxWidth:.infinity,maxHeight: .infinity, alignment: .top)
            // Concentric with the window: inner radius = window radius - inset, so both curves run parallel.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            // Below the toolbar row, so the round control has room above the card.
            // Starts right under the toolbar band, so the search button sits midway between the window edge and the card.
            .padding(.horizontal, cardInset).padding(.top, 0).padding(.bottom, cardInset)

            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) { sidebarControls }
            }


            SidebarResizeHandle(width: $sidebarWidth)
            Group {
                if store.workspaceSection == .contacts { ContactsWorkspace() }
                else if store.workspaceSection == .saved { SavedWorkspace() }
                // One conversation view serves every thread: rebuilding the composer, header and table per switch is what made switching slow.
                else if let thread = store.selectedThread { ConversationView(thread: thread) }
                else { welcomePanel }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)

        }
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if prioritySplit && store.supports("set_thread_priority") && store.searchText.isEmpty { PriorityTabs() }
            if !store.ready {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text("Mất kết nối. Dữ liệu có thể đã cũ.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Kết nối lại") { store.restart() }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let label = activeFilterLabel {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                    Text(verbatim: label).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Bỏ lọc") { clearFilters() }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.filteredThreads) { thread in
                        let selected = store.selectedThreadID == thread.id
                        Button { store.selectThread(thread.id) } label: {
                            ThreadRow(thread: thread, typing: store.typing, draft: store.draftPreview(thread.id),
                                      category: store.features.thread(thread.id)?.string("category") ?? "", selected: selected)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .animation(reducedMotion ? nil : .easeInOut(duration:0.16),value:selected)
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            // Right-click opens the animated menu; Control-click keeps the system menu.
                            .onHover { [hoveredThread] inside in
                                if inside { hoveredThread.id = thread.id } else if hoveredThread.id == thread.id { hoveredThread.id = nil }
                            }
                            .contextMenu { ThreadContextMenu(thread: thread) }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                if store.filteredThreads.isEmpty {
                    if store.threads.isEmpty && !store.busy.isDisjoint(with: ["bootstrap", "refresh_threads"]) {
                        ProgressView("Đang tải hội thoại…")
                    } else if !store.searchText.isEmpty {
                        ContentUnavailableView {
                            Label("Không có kết quả", systemImage: "magnifyingglass")
                        } description: { Text("Không có hội thoại khớp “\(store.searchText)”.") } actions: {
                            if store.supports("search_history") { Button("Tìm trong nội dung tin nhắn…") { store.showingHistorySearch = true } }
                        }
                    } else if store.threads.isEmpty {
                        ContentUnavailableView("Chưa có tin nhắn", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Nhấn nút soạn để bắt đầu trò chuyện."))
                    } else {
                        ContentUnavailableView("Không có hội thoại trong bộ lọc này", systemImage: "line.3.horizontal.decrease",
                                               description: Text("Chọn Bỏ lọc để xem tất cả."))
                    }
                }
            }
        }
    }

    /// Three round glass controls; search widens into a field and hides the other two.
    private var sidebarControls: some View {
        HStack(spacing: 10) {
            if searchOpen {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    NativeSearchField(text: $globalQuery, focusRequest: searchFocusRequest,
                                      onSubmit: { recentSearches.remember(globalQuery) }, onCancel: { closeSearch() })
                        .frame(maxWidth: .infinity)
                    if !globalQuery.isEmpty {
                        Button { recentSearches.remember(globalQuery); globalQuery = ""; searchFocusRequest = UUID() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .frame(maxWidth: .infinity)
                .nativeGlass(18)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                roundControl("xmark", help: "Đóng tìm kiếm (Esc)") { closeSearch() }.keyboardShortcut(.cancelAction)
            } else {
                // New chat, views, filters and the account live in the menu bar (Tệp, Xem, Zalolite).
                Spacer(minLength: 0)
                // Appears only when GitHub Releases has a newer Zalolite.
                UpdateToolbarButton()
                // Shown once a second account is kept on this Mac.
                if !store.demo, store.savedAccounts.contains(where: { $0.uin != store.session.uin }) { AccountSwitcherButton() }
                roundControl("magnifyingglass", help: "Tìm liên hệ, số điện thoại và tin nhắn (⌘K)") {
                    searchOpen = true; searchFocusRequest = UUID()
                }.keyboardShortcut("k", modifiers: .command)
            }
        }
        .frame(width: max(200, sidebarWidth - 84), alignment: .trailing)
        .animation(reducedMotion ? nil : .snappy(duration: 0.24), value: searchOpen)
    }

    private var cardInset: CGFloat { 8 }
    private var cardRadius: CGFloat { max(12, store.windowCornerRadius - cardInset) }

    private func roundControl(_ icon: String, help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Color(nsColor: .labelColor)).nativeGlass(18).help(help)
    }

    private func closeSearch() {
        recentSearches.remember(globalQuery)
        searchOpen = false; globalQuery = ""; store.historyResults = []
    }

    private var activeFilterLabel: String? {
        var parts: [String] = []
        if store.unreadOnly { parts.append("Chưa đọc") }
        if store.filter != .all { parts.append(store.filter.rawValue) }
        if !store.selectedCategory.isEmpty { parts.append(store.selectedCategory) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func clearFilters() {
        // The Ưu tiên / Khác tab is a view, not a filter, so it stays.
        store.unreadOnly = false; store.filter = .all; store.selectedCategory = ""
        if !prioritySplit { store.priorityFilter = "all" }
    }

    /// One menu carries sections, filters and the account, as the sidebar has no tab rail.
    private var filterMenu: some View {
        Menu {
            Section("Xem") {
                Button("Tin nhắn", systemImage: "message") { store.workspaceSection = .messages }
                Button("Danh bạ", systemImage: "person.2") { store.showContacts() }
                Button("Đã lưu và nhắc hẹn", systemImage: "bookmark") { store.workspaceSection = .saved; store.reloadWorkspaceFeatures() }
                if store.supports("list_scheduled") {
                    Button("Tin nhắn hẹn giờ…", systemImage: "clock") { store.showingScheduled = true; store.send("list_scheduled") }
                }
                if store.supports("search_history") {
                    Button("Tìm trong lịch sử…", systemImage: "text.magnifyingglass") { store.showingHistorySearch = true }
                }
            }
            Section("Lọc tin nhắn") {
                Toggle("Chỉ chưa đọc", isOn: $store.unreadOnly)
                Picker("Loại", selection: $store.filter) {
                    ForEach(AppStore.ThreadFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                Picker("Phân loại", selection: $store.selectedCategory) {
                    Text("Mọi phân loại").tag("")
                    ForEach(Array(Set(store.features.rows("thread_features").map { $0.string("category") }.filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Button("Làm mới hội thoại", systemImage: "arrow.clockwise") { store.send("refresh_threads") }
                    .disabled(!store.ready || store.busy.contains("refresh_threads"))
            }
            Section(store.session.name.isEmpty ? "Tài khoản Zalo" : store.session.name) {
                Text(verbatim: store.connection)
                Button("Thông tin tài khoản…", systemImage: "person.crop.circle") { store.showingAccountInfo = true }
                SettingsLink { Label("Cài đặt…", systemImage: "gearshape") }
                Button("Dữ liệu và dung lượng…", systemImage: "internaldrive") { store.requestedSettingsPage = "storage"; openSettings() }
                Button("Đồng bộ và sao lưu…", systemImage: "arrow.triangle.2.circlepath") { store.requestedSettingsPage = "sync"; openSettings() }
                Button("Hướng dẫn và hỗ trợ", systemImage: "questionmark.circle") {
                    if let url = URL(string: "https://github.com/ctdoteam1110/ctdozlite/tree/main/docs") { NSWorkspace.shared.open(url) }
                }
                if store.supports("logout") { Button("Đăng xuất…", role: .destructive) { store.showingLogoutConfirmation = true } }
                Button("Thoát Zalolite") { NSApp.terminate(nil) }
            }
        } label: { Image(systemName: activeFilterLabel == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill").font(.system(size: 15, weight: .medium)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 36, height: 36).contentShape(Circle()).nativeGlass(18).help("Xem, lọc và tài khoản")
    }

    private var composeMenu: some View {
        Menu {
            Button("Tìm bạn qua số điện thoại…", systemImage: "person.crop.circle.badge.plus") { store.showingContactLookup = true }
                .disabled(!store.supports("lookup_phone"))
            Button("Tạo nhóm…", systemImage: "person.3") { store.showingCreateGroup = true }.disabled(!store.supports("create_group"))
            Button("Chọn từ danh bạ", systemImage: "person.2") { store.showContacts() }
        } label: { Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 36, height: 36).contentShape(Circle()).nativeGlass(18).help("Cuộc trò chuyện mới")
    }

    private var welcomePanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
            Text("Chưa chọn cuộc trò chuyện").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            Text("Chọn một cuộc trò chuyện ở bên trái hoặc nhấn nút soạn.").font(.callout).foregroundStyle(.tertiary)
        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoginView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44, weight: .regular)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Chào mừng đến với Zalolite").font(.largeTitle.weight(.semibold))
                Text("Mở Zalo trên điện thoại, quét mã và xác nhận đăng nhập.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Group {
                if let image = store.qrImage {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Mã QR đăng nhập Zalo")
                } else {
                    VStack(spacing: 14) {
                        if store.busy.contains("request_qr") || !store.ready { ProgressView().controlSize(.large) }
                        else { Image(systemName: "qrcode").font(.system(size: 75, weight: .ultraLight)).foregroundStyle(.secondary) }
                        Text(store.busy.contains("request_qr") ? "Đang tạo mã QR…" : "Đăng nhập bằng mã QR")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: 230, height: 230)
            if store.ready {
                Button(store.qrImage == nil ? "Hiển thị mã QR" : "Tạo mã mới") { store.send("request_qr") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy.contains("request_qr"))
            } else if store.error != nil {
                Button("Mở lại ứng dụng") { store.restart() }.buttonStyle(.borderedProminent)
            }
            Text(verbatim: store.connection).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 430).multilineTextAlignment(.center)
            Spacer()
            HStack {
                Text("Phiên đăng nhập và lịch sử được lưu trên máy.")
                SettingsLink { Text("Cài đặt…") }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ThreadRow: View {
    let thread: ThreadSnapshot
    @ObservedObject var typing: TypingTracker
    var draft: String? = nil
    var category = ""
    var selected = false
    private var primary: Color { selected ? .white : Color(nsColor: .labelColor) }
    private var secondary: Color { selected ? .white.opacity(0.82) : Color(nsColor: .secondaryLabelColor) }
    /// Time today, weekday within a week, short date before that.
    private var stamp: String {
        let date = thread.date
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.defaultDigits).year(.twoDigits))
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(selected ? Color.white : Color.accentColor).frame(width: 8, height: 8)
                .opacity(thread.hasUnread ? 1 : 0)
            ThreadAvatar(thread: thread, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: thread.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(primary).lineLimit(1)
                    if !category.isEmpty {
                        Text(verbatim: category).font(.system(size: 9, weight: .medium)).lineLimit(1).foregroundStyle(primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(selected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if thread.lastMessageTimestamp > 0 {
                        Text(verbatim: stamp).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1).layoutPriority(1)
                    }
                }
                HStack(alignment: .top, spacing: 5) {
                    Group {
                        if !typing.users(in: thread.id).isEmpty {
                            HStack(spacing: 5) {
                                Text("Đang soạn tin").foregroundStyle(selected ? .white : Color.accentColor)
                                TypingDots(color: selected ? .white : .accentColor)
                            }
                        }
                        else if let draft { Text("Nháp: ").foregroundStyle(selected ? .white : .orange) + Text(verbatim: draft).foregroundStyle(secondary) }
                        else { Text(verbatim: thread.lastMessage).foregroundStyle(secondary) }
                    }.font(.system(size: 12.5)).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 29, alignment: .topLeading)
                    if thread.muted { Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(secondary) }
                    if thread.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(secondary) }
                    if thread.hasUnread {
                        Text(thread.unread == 0 ? " " : thread.unread > 99 ? "99+" : "\(thread.unread)").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : .white).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(selected ? Color.white : Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(thread.hasUnread ? (thread.unread > 0 ? "\(thread.unread) tin chưa đọc" : "Được đánh dấu chưa đọc") : "Đã đọc")
    }
}

struct ThreadContextMenu: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    var body: some View {
        if store.supports("pin_thread") {
            Button(thread.pinned ? "Bỏ ghim" : "Ghim cuộc trò chuyện", systemImage: thread.pinned ? "pin.slash" : "pin") {
                store.threadCommand("pin_thread", thread: thread, parameters: ["pin": .bool(!thread.pinned)])
            }
        }
        if store.supports("mute_thread") {
            Button(thread.muted ? "Bật thông báo" : "Tắt thông báo", systemImage: thread.muted ? "bell" : "bell.slash") {
                store.threadCommand("mute_thread", thread: thread, parameters: ["mute": .bool(!thread.muted)])
            }
        }
        Button("Tải lại tin nhắn", systemImage: "arrow.clockwise") { store.loadMessages(thread) }
        ThreadManagementMenu(thread: thread)
    }
}

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 40
    var group = false
    private var initial: String {
        let words = name.split(separator: " ")
        return words.suffix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
    var body: some View {
        Group {
            if let remote = safeWebURL(url) {
                AsyncImage(url: remote) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
    /// Neutral monogram disc; identity comes from the name, not from a per-contact colour.
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.69, green: 0.72, blue: 0.83), Color(red: 0.50, green: 0.54, blue: 0.68)],
                           startPoint: .top, endPoint: .bottom)
            if initial.isEmpty || group || initial.contains(where: { $0.isNumber }) {
                Image(systemName: group ? "person.2.fill" : "person.fill").font(.system(size: size * 0.44)).foregroundStyle(.white)
                    .offset(y: group ? 0 : size * 0.06)
            } else { Text(initial).font(.system(size: size * 0.38, weight: .medium, design: .rounded)).foregroundStyle(.white) }
        }
    }
}

/// Which conversation row the pointer is over; a reference so hovering does not re-render the list.
final class HoverBox { var id: String? }

struct ThreadMenuTarget {
    let thread: ThreadSnapshot
    let point: CGPoint
    var id: String { thread.id + "@\(Int(point.x)),\(Int(point.y))" }
}
