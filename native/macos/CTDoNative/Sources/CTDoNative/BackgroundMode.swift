import AppKit
import SwiftUI
import NativeBridge

/// Running in the background, as Zalo does: closing the window keeps the Rust worker connected,
/// so messages, calls and sync continue and notifications still arrive.
enum BackgroundMode {
    static let keepRunningKey = "nativeKeepRunning"
    static let menuBarKey = "nativeMenuBarIcon"
    static let hideDockKey = "nativeHideDockInBackground"
    static let showWindowNotification = Notification.Name("com.ctdoteam1110.zalolite.showMainWindow")

    static var keepRunning: Bool { UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true }
    static var hidesDock: Bool { UserDefaults.standard.bool(forKey: hideDockKey) }
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("--demo") }
    /// The conversation window is on screen; with it closed or hidden the user is not reading anything.
    @MainActor static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    /// Lifecycle notes (window closed, quit requested, reopen) without any account data, so an
    /// unexpected exit while running in the background can be traced.
    static func note(_ event: String) {
        guard !isDemo, let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let file = base.appendingPathComponent("ctdozlite-native/app_lifecycle.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(event)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 512_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// App Nap would delay socket reads and notification delivery while no window is visible.
    @MainActor private static var activity: NSObjectProtocol?
    @MainActor static func preventAppNap() {
        guard activity == nil, !isDemo else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Nhận tin nhắn và cuộc gọi Zalo")
    }

    /// Called after the main window closed: optionally leave the Dock and live in the menu bar only.
    @MainActor static func windowClosed() {
        guard keepRunning, hidesDock, !isDemo,
              !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Brings the main window back, restoring the Dock icon first when it was hidden.
    @MainActor static func showMainWindow(_ open: OpenWindowAction) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open(id: "main")
        }
    }
}

extension AppStore {
    /// Shows the main window from anywhere, recreating it if it was closed.
    func showMainWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) { window.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
    }
}

/// Menu bar icon with the unread total, like the badge on the Dock.
struct MenuBarLabel: View {
    @ObservedObject var store: AppStore
    private var unread: Int { store.threads.filter { !$0.muted && !$0.hidden }.reduce(0) { $0 + $1.unread } }
    var body: some View {
        if unread > 0 {
            Label(unread > 99 ? "99+" : "\(unread)", systemImage: "bubble.left.and.bubble.right.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
        }
    }
}

/// The menu shown from the menu bar icon while Zalolite runs in the background.
struct MenuBarContent: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @OpenSettingsCompat private var openSettings

    private var unreadThreads: [ThreadSnapshot] {
        Array(store.threads.filter { $0.unread > 0 && !$0.hidden && !$0.muted }
            .sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }.prefix(6))
    }

    var body: some View {
        Text(store.session.loggedIn ? (store.ready ? "Đang chạy nền · đã kết nối" : store.connection) : "Chưa đăng nhập")
        Divider()
        if unreadThreads.isEmpty {
            Text("Không có tin nhắn chưa đọc")
        } else {
            ForEach(unreadThreads) { thread in
                Button("\(thread.name) (\(thread.unread))") {
                    BackgroundMode.showMainWindow(openWindow)
                    if !store.isLocked { store.workspaceSection = .messages; store.selectThread(thread.id) }
                }
            }
        }
        Divider()
        Button("Mở Zalolite") { BackgroundMode.showMainWindow(openWindow) }.keyboardShortcut("o")
        Button("Cài đặt…") { NSApp.activate(ignoringOtherApps: true); openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Thoát Zalolite") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
