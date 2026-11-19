import AppKit
import Combine
import SwiftUI
import NativeBridge

/// Floating chat bubbles: while the main window is not in front, conversations that receive new messages
/// appear as avatars at the screen edge, above other apps. Clicking one opens a small chat beside it.
@MainActor
final class ChatHeads: ObservableObject {
    static let shared = ChatHeads()
    static let enabledKey = "nativeChatHeads"
    private static let edgeKey = "nativeChatHeadsEdge"
    private static let topKey = "nativeChatHeadsTop"
    static let maxHeads = 5
    static let avatarSize: CGFloat = 52
    private static let padding: CGFloat = 14
    private static let spacing: CGFloat = 10
    static let chatSize = NSSize(width: 360, height: 500)

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Thread IDs, newest first.
    @Published private(set) var heads: [String] = []
    /// The conversation whose small chat is open.
    @Published private(set) var openID: String?
    /// Grows each time a conversation receives a message, so its bubble bounces.
    @Published private(set) var pulses: [String: Int] = [:]
    /// Messages that arrived on each bubble since its chat was last opened.
    @Published private(set) var unseen: [String: Int] = [:]
    /// The newest message shown as a card beside its bubble for a few seconds.
    @Published private(set) var preview: ChatHeadPreview?
    /// The bubble column sits on the right edge; the chat and card open towards the left.
    @Published private(set) var onRightEdge = true

    private weak var store: AppStore?
    private var stackPanel: FloatingPanel?
    private var chatPanel: FloatingPanel?
    private var previewPanel: FloatingPanel?
    private static let previewSize = NSSize(width: 270, height: 76)
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var subscriptions: Set<AnyCancellable> = []
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// The conversation shown in an open, visible small chat; it counts as being read.
    var readingThreadID: String? { chatPanel?.isVisible == true ? openID : nil }

    func attach(_ store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        subscriptions.removeAll()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] note in
                MainActor.assumeIsolated { self?.windowFocusChanged(note) }
            }.store(in: &subscriptions)
        }
        store.$isLocked.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }.store(in: &subscriptions)
        store.$session.map(\.uin).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.clear() } }
        }.store(in: &subscriptions)
        store.$threads.sink { [weak self] threads in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.prune(threads) } }
        }.store(in: &subscriptions)
        center.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { if !ChatHeads.enabled, self?.heads.isEmpty == false { self?.clear() } }
        }.store(in: &subscriptions)
    }

    // MARK: State changes

    /// New messages arrived for these conversations. Bubbles are added only while the user is away from
    /// the main window; in front of it the conversation list already shows them.
    func noteIncoming(_ threads: [ThreadSnapshot]) {
        guard Self.enabled, !threads.isEmpty, !mainWindowInFront else { return }
        announce(threads)
    }

    private func announce(_ threads: [ThreadSnapshot]) {
        for thread in threads.reversed() {
            if openID != thread.id { insert(thread.id); unseen[thread.id, default: 0] += 1 }
            pulses[thread.id, default: 0] += 1
        }
        // The open conversation already shows the message; announce the newest of the others.
        if let newest = threads.first(where: { $0.id != openID }) {
            let defaults = UserDefaults.standard
            let full = defaults.object(forKey: "nativeNotificationPreview") as? Bool ?? true
            let text = full && !newest.lastMessage.isEmpty ? newest.lastMessage : "Bạn có tin nhắn mới"
            let card = ChatHeadPreview(threadID: newest.id, name: newest.name, text: text)
            preview = card
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { if self?.preview?.token == card.token { self?.dismissPreview() } }
            }
        }
        refresh()
    }

    func dismissPreview() {
        guard preview != nil else { return }
        preview = nil
        refresh()
    }

    /// Opens the conversation announced by the card.
    func openPreview() {
        guard let id = preview?.threadID else { return }
        preview = nil
        show(id)
    }

    /// Pops a conversation out into a bubble and opens it.
    func open(_ threadID: String) {
        insert(threadID)
        show(threadID)
    }

    func toggle(_ threadID: String) {
        if openID == threadID && chatPanel?.isVisible == true { collapse() } else { show(threadID) }
    }

    func collapse() {
        openID = nil
        refresh()
    }

    func remove(_ threadID: String) {
        heads.removeAll { $0 == threadID }
        unseen[threadID] = nil
        if openID == threadID { openID = nil }
        if preview?.threadID == threadID { preview = nil }
        refresh()
    }

    func clear() {
        heads = []; openID = nil; preview = nil; pulses = [:]; unseen = [:]
        refresh()
    }

    /// Leaves the bubble and shows the conversation in the main window.
    func openInMainWindow(_ threadID: String) {
        guard let store else { return }
        remove(threadID)
        store.showMainWindow()
        if !store.isLocked { store.workspaceSection = .messages; store.selectThread(threadID) }
    }

    private func insert(_ threadID: String) {
        heads.removeAll { $0 == threadID }
        heads.insert(threadID, at: 0)
        // The oldest closed bubble makes room; the open one stays.
        while heads.count > Self.maxHeads, let victim = heads.last(where: { $0 != openID }) { heads.removeAll { $0 == victim } }
    }

    private func show(_ threadID: String) {
        guard let store, !store.isLocked else { return }
        // The small chat sends through the normal composer path, which follows the selected conversation.
        store.workspaceSection = .messages
        store.selectThread(threadID)
        guard store.selectedThreadID == threadID else { return }
        openID = threadID
        unseen[threadID] = nil
        if preview?.threadID == threadID { preview = nil }
        refresh()
        chatPanel?.makeKeyAndOrderFront(nil)
        store.markSelectedReadIfVisible()
    }

    private func prune(_ threads: [ThreadSnapshot]) {
        // Development-only: `--demo --demo-chat-heads` shows bubbles for screenshots without live messages.
        if BackgroundMode.isDemo, heads.isEmpty, !threads.isEmpty,
           ProcessInfo.processInfo.arguments.contains("--demo-chat-heads") {
            for thread in threads.prefix(3).reversed() { insert(thread.id) }
            show(threads[0].id)
            // A pretend message every 10 seconds shows the bounce and the preview card.
            if let other = threads.dropFirst().first {
                Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, var thread = self.store?.threads.first(where: { $0.id == other.id }) else { return }
                        thread.lastMessage = "Tin nhắn minh họa lúc " + Date().formatted(date: .omitted, time: .standard)
                        self.announce([thread])
                    }
                }
            }
            if let folder = ProcessInfo.processInfo.environment["CTDOZLITE_CHAT_HEADS_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    MainActor.assumeIsolated {
                        for (name, panel) in [("stack", self?.stackPanel), ("chat", self?.chatPanel)] {
                            guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-heads-\(name).png"))
                        }
                    }
                }
            }
            return
        }
        guard !threads.isEmpty, !heads.isEmpty else { return }
        let known = Set(threads.filter { !$0.hidden }.map(\.id))
        let kept = heads.filter(known.contains)
        guard kept != heads else { return }
        heads = kept
        if let openID, !known.contains(openID) { self.openID = nil }
        refresh()
    }

    private var mainWindowInFront: Bool {
        NSApp.isActive && NSApp.keyWindow?.identifier?.rawValue == "main"
    }

    private func windowFocusChanged(_ note: Notification) {
        // Back in the main window: it shows the same conversation, so the small chat folds away.
        if mainWindowInFront, openID != nil { openID = nil }
        if (note.object as? NSWindow) === chatPanel, note.name == NSWindow.didBecomeKeyNotification,
           let openID, let store, store.selectedThreadID != openID {
            store.selectThread(openID)
        }
        refresh()
    }

    // MARK: Panels

    func refresh() {
        guard let store else { return }
        let visible = Self.enabled && store.session.loggedIn && !store.isLocked && !heads.isEmpty
            && (openID != nil || !mainWindowInFront)
        guard visible else {
            fadeOut(stackPanel); fadeOut(chatPanel); fadeOut(previewPanel)
            return
        }
        let stack = stackPanel ?? makeStackPanel(store)
        stackPanel = stack
        let size = stackSize
        let screen = stack.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let area = screen.visibleFrame
            let rightEdge = UserDefaults.standard.string(forKey: Self.edgeKey) != "left"
            if onRightEdge != rightEdge { onRightEdge = rightEdge }
            let top = UserDefaults.standard.object(forKey: Self.topKey) as? Double ?? 140
            let x = rightEdge ? area.maxX - size.width - 6 : area.minX + 6
            let y = min(area.maxY - size.height, max(area.minY, area.maxY - CGFloat(top) - size.height))
            if dragStart == nil { stack.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true) }
        }
        fadeIn(stack)

        if let openID, heads.contains(openID) {
            let chat = chatPanel ?? makeChatPanel(store)
            chatPanel = chat
            placeChat(chat)
            fadeIn(chat)
        } else {
            fadeOut(chatPanel)
        }

        // The card would cover the open chat, so it waits until the chat is folded.
        if let preview, openID == nil, heads.contains(preview.threadID), dragStart == nil {
            let card = previewPanel ?? makePreviewPanel(store)
            previewPanel = card
            placePreview(card, threadID: preview.threadID)
            fadeIn(card)
        } else {
            fadeOut(previewPanel)
        }
    }

    /// Panels fade rather than pop; with Reduce Motion they appear and leave at once.
    private func fadeIn(_ panel: FloatingPanel) {
        panel.animationToken += 1
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible { panel.alphaValue = Self.reduceMotion ? 1 : 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ panel: FloatingPanel?) {
        guard let panel, panel.isVisible else { return }
        panel.animationToken += 1
        let token = panel.animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if panel.animationToken == token { panel.orderOut(nil); panel.alphaValue = 1 } }
        })
    }

    private func placePreview(_ card: NSPanel, threadID: String) {
        guard let stack = stackPanel, let area = (stack.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = Self.previewSize
        let index = CGFloat(heads.firstIndex(of: threadID) ?? 0)
        let bubbleMidY = stack.frame.maxY - Self.padding - index * (Self.avatarSize + Self.spacing) - Self.avatarSize / 2
        var x = onRightEdge ? stack.frame.minX - size.width + 6 : stack.frame.maxX - 6
        x = min(area.maxX - size.width, max(area.minX, x))
        let y = min(area.maxY - size.height, max(area.minY, bubbleMidY - size.height / 2))
        card.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func makePreviewPanel(_ store: AppStore) -> FloatingPanel {
        let panel = FloatingPanel(key: false)
        panel.contentView = NSHostingView(rootView: ChatHeadPreviewCard(heads: self).environmentObject(store))
        return panel
    }

    private var stackSize: NSSize {
        let count = CGFloat(max(1, heads.count))
        return NSSize(width: Self.avatarSize + Self.padding * 2,
                      height: count * Self.avatarSize + (count - 1) * Self.spacing + Self.padding * 2)
    }

    private func placeChat(_ chat: NSPanel) {
        guard let stack = stackPanel, let area = (stack.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = Self.chatSize
        let rightEdge = stack.frame.midX > area.midX
        var x = rightEdge ? stack.frame.minX - size.width + 4 : stack.frame.maxX - 4
        x = min(area.maxX - size.width, max(area.minX, x))
        // Top-aligned with the bubble that opened it, kept on screen.
        let index = CGFloat(heads.firstIndex(of: openID ?? "") ?? 0)
        let bubbleTop = stack.frame.maxY - Self.padding - index * (Self.avatarSize + Self.spacing)
        let y = min(area.maxY - size.height, max(area.minY, bubbleTop - size.height + 8))
        chat.setFrame(NSRect(x: x, y: max(area.minY, y), width: size.width, height: size.height), display: true)
    }

    private func makeStackPanel(_ store: AppStore) -> FloatingPanel {
        let panel = FloatingPanel(key: false)
        panel.contentView = NSHostingView(rootView: ChatHeadStack(heads: self).environmentObject(store))
        return panel
    }

    private func makeChatPanel(_ store: AppStore) -> FloatingPanel {
        let panel = FloatingPanel(key: true)
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ChatHeadWindow(heads: self).environmentObject(store))
        return panel
    }

    // MARK: Dragging the bubbles

    /// Moves the bubble column with the pointer; screen coordinates keep it steady while the window moves.
    func drag() {
        guard let stack = stackPanel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, stack.frame.origin); chatPanel?.orderOut(nil); previewPanel?.orderOut(nil) }
        guard let start = dragStart else { return }
        stack.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// Snaps the column to the nearer side of the screen it was dropped on and remembers the place.
    func endDrag() {
        guard let stack = stackPanel else { dragStart = nil; return }
        dragStart = nil
        let center = NSPoint(x: stack.frame.midX, y: stack.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? stack.screen ?? NSScreen.main
        if let area = screen?.visibleFrame {
            UserDefaults.standard.set(center.x < area.midX ? "left" : "right", forKey: Self.edgeKey)
            UserDefaults.standard.set(Double(max(0, area.maxY - stack.frame.maxY)), forKey: Self.topKey)
            // Move onto the target screen first so refresh() measures against it.
            if stack.screen != screen { stack.setFrameOrigin(NSPoint(x: area.midX, y: area.midY)) }
        }
        refresh()
    }
}

/// Borderless panel above other apps that never activates Zalolite, so the main window stays put.
final class FloatingPanel: NSPanel {
    private let acceptsKey: Bool
    /// Bumped by every fade so a finished fade-out never hides a panel shown again meanwhile.
    var animationToken = 0
    init(key: Bool) {
        acceptsKey = key
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        identifier = NSUserInterfaceItemIdentifier(key ? "chat-head-conversation" : "chat-heads")
        let appearance = UserDefaults.standard.string(forKey: "nativeAppearance")
        self.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// A new message announced beside its bubble.
struct ChatHeadPreview: Equatable {
    let threadID: String
    let name: String
    let text: String
    let token = UUID()
}

// MARK: - Views

/// Liquid Glass on macOS 26; a material on older systems and an opaque fill with Reduce Transparency.
private struct ChatHeadGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    var tint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape).background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.clear), in: shape)
        }
    }
}

private extension View {
    func chatHeadGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(ChatHeadGlass(shape: shape, interactive: interactive, tint: tint))
    }

    /// Lets neighbouring glass shapes blend into each other, as system glass groups do.
    @ViewBuilder func chatHeadGlassGroup(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

struct ChatHeadStack: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var heads: ChatHeads
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        VStack(spacing: 10) {
            ForEach(heads.heads, id: \.self) { id in
                if let thread = store.threads.first(where: { $0.id == id }) {
                    ChatHeadBubble(thread: thread, isOpen: heads.openID == id, pulse: heads.pulses[id] ?? 0,
                                   unread: max(thread.unread, heads.unseen[id] ?? 0, thread.markedUnread ? 1 : 0), heads: heads)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
        }
        .animation(reducedMotion ? nil : .spring(response: 0.42, dampingFraction: 0.68), value: heads.heads)
        .chatHeadGlassGroup(spacing: 10)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ChatHeadBubble: View {
    let thread: ThreadSnapshot
    let isOpen: Bool
    let pulse: Int
    /// Zalo's unread count, or the messages counted here since the bubble was last opened.
    let unread: Int
    let heads: ChatHeads
    @State private var hovering = false
    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let size = ChatHeads.avatarSize
    private let ring: CGFloat = 4

    var body: some View {
        ThreadAvatar(thread: thread, size: size - ring * 2)
            .clipShape(Circle())
            .padding(ring)
            // The avatar sits in a glass disc; the open conversation's disc takes the accent tint.
            .chatHeadGlass(Circle(), interactive: true, tint: isOpen ? Color.accentColor.opacity(0.55) : nil)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .scaleEffect(bounce ? 1.16 : hovering ? 1.05 : 1)
            .rotationEffect(.degrees(bounce ? -6 : 0))
            .animation(reducedMotion ? nil : .spring(response: 0.28, dampingFraction: 0.45), value: bounce)
            .animation(reducedMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            // A new message makes the bubble hop once, like a tap on the shoulder.
            .onValueChange(of: pulse) { _, _ in
                guard !reducedMotion else { return }
                bounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { bounce = false }
            }
            .overlay(alignment: .topTrailing) {
                if unread > 0 && !isOpen {
                    // Like the Dock badge: a red disc with the count, ringed so it reads on any avatar.
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Color.red))
                        .overlay { Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: 6, y: -5)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(reducedMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: unread)
            .animation(reducedMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: isOpen)
            .overlay(alignment: .topLeading) {
                if hovering {
                    Button { heads.remove(thread.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 20, height: 20)
                            .chatHeadGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain).offset(x: -5, y: -4).help("Đóng bong bóng")
                }
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture { heads.toggle(thread.id) }
            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in heads.drag() }.onEnded { _ in heads.endDrag() })
            .contextMenu {
                Button(isOpen ? "Thu nhỏ" : "Mở trò chuyện") { heads.toggle(thread.id) }
                Button("Mở trong Zalolite") { heads.openInMainWindow(thread.id) }
                Divider()
                Button("Đóng bong bóng") { heads.remove(thread.id) }
                Button("Đóng tất cả bong bóng") { heads.clear() }
            }
            .help(thread.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unread > 0 ? "\(thread.name), \(unread) tin chưa đọc" : thread.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { heads.toggle(thread.id) }
    }
}

/// The small chat opened from a bubble: a glass sheet with floating glass header and composer.
struct ChatHeadWindow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var heads: ChatHeads
    private static let width = ChatHeads.chatSize.width
    private static let radius: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    /// Grows out of the bubble each time a conversation opens.
    @State private var shown = false

    private var thread: ThreadSnapshot? { heads.openID.flatMap { id in store.threads.first { $0.id == id } } }
    private var messages: [MessageSnapshot] { Array((store.messages[heads.openID ?? ""] ?? []).suffix(80)) }

    var body: some View {
        Group {
            if let thread {
                transcript(thread)
                    // Messages scroll underneath the floating header and composer.
                    .safeAreaInset(edge: .top, spacing: 0) { header(thread).padding(.horizontal, 8).padding(.top, 8) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer(thread).padding(.horizontal, 8).padding(.bottom, 8) }
            } else {
                Color.clear
            }
        }
        .frame(width: Self.width, height: ChatHeads.chatSize.height)
        .chatHeadGlass(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .scaleEffect(shown || reducedMotion ? 1 : 0.86, anchor: heads.onRightEdge ? .topTrailing : .topLeading)
        .opacity(shown || reducedMotion ? 1 : 0)
        .environment(\.transcriptColumnWidth, Self.width)
        .onAppear { reveal() }
        .onValueChange(of: heads.openID) { _, id in if id != nil { reveal() } }
    }

    private func reveal() {
        shown = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { shown = true }
    }

    private func header(_ thread: ThreadSnapshot) -> some View {
        HStack(spacing: 10) {
            ThreadAvatar(thread: thread, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: thread.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if thread.isGroup, let total = thread.memberTotal {
                    Text("\(total) thành viên").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                glassButton("arrow.up.left.and.arrow.down.right", help: "Mở trong Zalolite") { heads.openInMainWindow(thread.id) }
                glassButton("minus", help: "Thu nhỏ") { heads.collapse() }.keyboardShortcut(.cancelAction)
                glassButton("xmark", help: "Đóng bong bóng") { heads.remove(thread.id) }
            }
            .chatHeadGlassGroup(spacing: 6)
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 5)
        .chatHeadGlass(Capsule())
    }

    private func glassButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .chatHeadGlass(Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func transcript(_ thread: ThreadSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if messages.isEmpty {
                        Text(store.busy.contains("load_message_page") || store.busy.contains("load_messages") ? "Đang tải tin nhắn…" : "Chưa có tin nhắn")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        row(message, previous: index > 0 ? messages[index - 1] : nil,
                            next: index + 1 < messages.count ? messages[index + 1] : nil, thread: thread)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onValueChange(of: messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onValueChange(of: heads.openID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ message: MessageSnapshot, previous: MessageSnapshot?, next: MessageSnapshot?, thread: ThreadSnapshot) -> some View {
        if message.messageType == "chat.system" {
            Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 6)
        } else {
            let opensRun = previous == nil || previous?.senderID != message.senderID || previous?.messageType == "chat.system"
            let endsRun = next == nil || next?.senderID != message.senderID || next?.messageType == "chat.system"
            let identity = store.senderIdentity(message, in: thread)
            MessageRow(message: message, showSender: thread.isGroup && !message.isOutgoing && opensRun,
                       showAvatar: !message.isOutgoing && endsRun, reserveAvatar: !message.isOutgoing,
                       senderName: identity.name, senderAvatar: identity.avatar, senderID: identity.id,
                       firstInRun: opensRun, lastInRun: endsRun, isGroup: thread.isGroup,
                       onQuoteJump: { _ in heads.openInMainWindow(thread.id) })
                .equatable()
                .padding(.top, opensRun ? 6 : 0)
        }
    }

    private func composer(_ thread: ThreadSnapshot) -> some View {
        let ready = store.canSend && store.selectedThreadID == thread.id
        let empty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            NativeComposer(text: $store.draft, enabled: ready, focusRequest: heads.openID, onSend: { submit(thread) })
                .padding(.horizontal, 8)
                .chatHeadGlass(RoundedRectangle(cornerRadius: 19, style: .continuous))
            Button { submit(thread) } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(empty ? Color.secondary : Color.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .chatHeadGlass(Circle(), interactive: true, tint: empty ? nil : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!ready || empty)
            .help("Gửi")
        }
        .chatHeadGlassGroup(spacing: 8)
    }

    private func submit(_ thread: ThreadSnapshot) {
        guard store.selectedThreadID == thread.id else { return }
        store.submitComposer()
    }
}

/// The newest message beside its bubble; clicking it opens the conversation.
struct ChatHeadPreviewCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var heads: ChatHeads
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Group {
            if let preview = heads.preview {
                HStack(spacing: 10) {
                    if let thread = store.threads.first(where: { $0.id == preview.threadID }) {
                        ThreadAvatar(thread: thread, size: 38)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: preview.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(verbatim: preview.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .chatHeadGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button { heads.dismissPreview() } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18).chatHeadGlass(Circle(), interactive: true)
                        }
                        .buttonStyle(.plain).padding(6).help("Ẩn")
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { heads.openPreview() }
                .onHover { hovering = $0 }
                .offset(x: shown || reducedMotion ? 0 : (heads.onRightEdge ? 28 : -28))
                .opacity(shown || reducedMotion ? 1 : 0)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tin nhắn mới từ \(preview.name): \(preview.text)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { heads.openPreview() }
                .onAppear { slideIn() }
                .onValueChange(of: preview.token) { _, _ in slideIn() }
            }
        }
        .padding(4)
    }

    private func slideIn() {
        shown = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { shown = true }
    }
}
