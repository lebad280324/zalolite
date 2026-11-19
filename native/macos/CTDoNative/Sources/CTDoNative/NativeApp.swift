import AppKit
import SwiftUI
import UserNotifications

@main
struct CTDoNativeApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(NativeAppDelegate.self) private var delegate
    @AppStorage("nativeAppearance") private var appearance = "system"
    @AppStorage("nativeCaptureKey") private var captureKey = "s"
    @AppStorage("nativeCaptureHiddenKey") private var captureHiddenKey = "a"
    @AppStorage(BackgroundMode.menuBarKey) private var menuBarIcon = true

    var body: some Scene {
        Window("Zalolite", id: "main") {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .frame(minWidth: 760, minHeight: 540)
                .task { delegate.store = store; ChatHeads.shared.attach(store); store.start(); SoftwareUpdater.shared.checkIfDue(); await exportDemoSnapshotIfRequested(store); await runTranscriptFrameProbeIfRequested(store) }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                UpdateMenuItem { openSettingsPage("updates") }
            }
            CommandGroup(after: .appSettings) {
                Button("Thông tin tài khoản…") { store.showingAccountInfo = true }.disabled(!store.session.loggedIn)
                Button("Dữ liệu và dung lượng…") { openSettingsPage("storage") }
                Button("Đồng bộ và sao lưu…") { openSettingsPage("sync") }
                Divider()
                AccountMenuItems(store: store)
                Button("Đăng xuất…") { store.showingLogoutConfirmation = true }
                    .disabled(!store.session.loggedIn || !store.supports("logout"))
            }
            CommandGroup(replacing: .help) {
                Button("Hướng dẫn và hỗ trợ Zalolite") {
                    if let url = URL(string: "https://github.com/ctdoteam1110/ctdozlite/tree/main/docs") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(before: .toolbar) {
                Section {
                    Button("Tin nhắn") { store.workspaceSection = .messages }.keyboardShortcut("1", modifiers: .command).disabled(!store.session.loggedIn)
                    Button("Danh bạ") { store.showContacts() }.keyboardShortcut("2", modifiers: .command).disabled(!store.session.loggedIn)
                    Button("Đã lưu và nhắc hẹn") { store.workspaceSection = .saved; store.reloadWorkspaceFeatures() }.keyboardShortcut("3", modifiers: .command).disabled(!store.session.loggedIn)
                    Button("Tin nhắn hẹn giờ…") { store.showingScheduled = true; store.send("list_scheduled") }
                        .disabled(!store.session.loggedIn || !store.supports("list_scheduled"))
                }
                Divider()
                Section("Lọc tin nhắn") {
                    Toggle("Chỉ tin chưa đọc", isOn: $store.unreadOnly).keyboardShortcut("u", modifiers: [.command, .shift])
                    Picker("Loại hội thoại", selection: $store.filter) {
                        ForEach(AppStore.ThreadFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                    }
                    if store.supports("set_thread_priority") {
                        Picker("Mức ưu tiên", selection: $store.priorityFilter) {
                            Text("Tất cả").tag("all"); Text("Ưu tiên").tag("priority"); Text("Khác").tag("other")
                        }
                    }
                    Picker("Phân loại", selection: $store.selectedCategory) {
                        Text("Mọi phân loại").tag("")
                        ForEach(Array(Set(store.features.rows("thread_features").map { $0.string("category") }.filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Button("Bỏ mọi bộ lọc") { store.unreadOnly = false; store.filter = .all; store.priorityFilter = "all"; store.selectedCategory = "" }
                }
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("Chọn từ danh bạ…") { store.showContacts() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!store.session.loggedIn)
                Button("Tìm bạn qua số điện thoại…") { store.showingContactLookup = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!store.session.loggedIn || !store.supports("lookup_phone"))
                Button("Tạo nhóm…") { store.showContacts(); store.showingCreateGroup = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.session.loggedIn || !store.supports("create_group"))
                Button("Tải lại tin nhắn") { store.send("refresh_threads") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.ready || !store.session.loggedIn)
            }
            CommandMenu("Cuộc trò chuyện") {
                Button("Khóa ứng dụng") { store.isLocked = true }.keyboardShortcut("l", modifiers: [.command, .control]).disabled(!store.session.loggedIn)
                Button("Chụp màn hình…") { NativeSystem.captureScreen(hideApp: false) }.keyboardShortcut(KeyEquivalent(captureKey.first ?? "s"), modifiers: [.command, .option])
                Button("Ẩn ứng dụng rồi chụp…") { NativeSystem.captureScreen(hideApp: true) }.keyboardShortcut(KeyEquivalent(captureHiddenKey.first ?? "a"), modifiers: [.command, .option])
                Divider()
                Button("Tìm trong cuộc trò chuyện") { store.showingConversationSearch = true }
                    .keyboardShortcut("f", modifiers: .command).disabled(store.selectedThread == nil)
                Button("Tìm trong lịch sử…") { store.showingHistorySearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!store.session.loggedIn || !store.supports("search_history"))
                Button("Tin nhắn nhanh…") { store.showingQuickReplies = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!store.session.loggedIn || !store.supports("upsert_quick_reply"))
                Divider()
                Button("Gửi tin nhắn") { store.submitComposer() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSend)
                Button("Đính kèm tệp…") { store.chooseAttachment() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(!store.canSend || !store.supports("send_attachment"))
                Divider()
                Button("Thông tin cuộc trò chuyện") { store.showingInspector.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(store.selectedThread == nil)
            }
        }
        Settings {
            SettingsView().environmentObject(store)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        // Settings opened at a fixed size; it now resizes down to the content's minimum.
        .windowResizability(.contentMinSize)
        // Stays reachable while the window is closed and the app keeps running in the background.
        MenuBarExtra(isInserted: Binding(get: { menuBarIcon && !BackgroundMode.isDemo }, set: { menuBarIcon = $0 })) {
            MenuBarContent().environmentObject(store)
        } label: { MenuBarLabel(store: store) }
    }
}

@MainActor
extension CTDoNativeApp {
    /// Opens Settings on a page through the app menu's own ⌘, item, as SwiftUI provides no menu-side call.
    func openSettingsPage(_ key: String) {
        store.requestedSettingsPage = key
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
           let menu = item.menu, let index = menu.items.firstIndex(of: item) { menu.performActionForItem(at: index) }
    }
}

@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Demo windows use a throwaway data folder, so they may run beside the signed-in app.
        if !ProcessInfo.processInfo.arguments.contains("--demo"), let identifier=Bundle.main.bundleIdentifier,
           let existing=NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            // The running copy may be in the background with its window closed: ask it to show the
            // window, then leave at once. This copy has started nothing, so the normal shutdown
            // (which waits for the Rust worker) is skipped; it used to hang there.
            DistributedNotificationCenter.default().postNotificationName(BackgroundMode.showWindowNotification, object: identifier,
                                                                        userInfo: nil, deliverImmediately: true)
            existing.activate(options:[.activateIgnoringOtherApps])
            exit(0)
        }
        CursorThrift.install()
        NSApp.setActivationPolicy(.regular)
        BackgroundMode.preventAppNap()
        BackgroundMode.note("launched keepRunning=\(BackgroundMode.keepRunning)")
        // A second launch (Dock, Finder, `open -n`) asks this copy to bring its window back.
        DistributedNotificationCenter.default().addObserver(forName: BackgroundMode.showWindowNotification, object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.showMainWindow() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue == "main" else { return }
            BackgroundMode.note("main window closed")
            // Let the window finish closing before deciding whether the Dock icon goes away.
            DispatchQueue.main.async { MainActor.assumeIsolated { BackgroundMode.windowClosed() } }
        }
        NSApp.activate(ignoringOtherApps: true)
        // UserNotifications is only available to a bundled application.
        if Bundle.main.bundleIdentifier != nil && !ProcessInfo.processInfo.arguments.contains("--demo") {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            // Calls can be answered or declined straight from the banner.
            let accept = UNNotificationAction(identifier: "call.accept", title: "Trả lời", options: [.foreground])
            let decline = UNNotificationAction(identifier: "call.decline", title: "Từ chối", options: [.destructive])
            center.setNotificationCategories([UNNotificationCategory(identifier: "incoming_call", actions: [accept, decline], intentIdentifiers: [])])
            // Without a prompt macOS drops every banner silently, so ask once on first launch.
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }
    /// Opening a message notification selects its conversation by stable ID.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadID = response.notification.request.content.userInfo["thread_id"] as? String
        let action = response.actionIdentifier
        if action == "call.accept" || action == "call.decline" {
            await MainActor.run {
                guard let store = self.store, store.features.incomingCall != nil else { return }
                store.send("answer_call", parameters: ["accept": .bool(action == "call.accept"), "cam_start_off": .bool(action != "call.accept")])
                store.features.incomingCall = nil
                if action == "call.accept" { NSApp.activate(ignoringOtherApps: true) }
            }
            return
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let threadID, self.store?.isLocked == false { self.store?.workspaceSection = .messages; self.store?.selectThread(threadID) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        store?.markSelectedReadIfVisible()
    }
    func applicationDidResignActive(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "nativeLockOnDeactivate"), store?.session.loggedIn == true { store?.isLocked = true }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSApp.currentEvent
        BackgroundMode.note("quit requested event=\(event.map { "\($0.type.rawValue)/\($0.charactersIgnoringModifiers ?? "")" } ?? "none") windows=\(NSApp.windows.filter(\.isVisible).count)")
        // A downloaded update the user left for later is installed once this process exits.
        SoftwareUpdater.shared.installStagedOnQuit()
        guard let store else { return .terminateNow }
        store.stop {
            Task { @MainActor in sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    /// Closing the window keeps Zalolite connected in the background unless the user turned that off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !BackgroundMode.keepRunning }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BackgroundMode.note("reopen visibleWindows=\(flag)")
        // Floating chat bubbles are visible windows too; only the main window counts here.
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { store?.showMainWindow() }
        return true
    }
}
