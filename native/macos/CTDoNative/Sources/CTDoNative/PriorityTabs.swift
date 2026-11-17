import SwiftUI
import AppKit

/// "Ưu tiên | Khác" tabs above the conversation list, like Zalo. The split comes from the same
/// server list the phone and Zalo PC use, so moving a conversation shows up everywhere.
struct PriorityTabs: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("nativePrioritySplit") private var prioritySplit = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Namespace private var underline
    @State private var lastRefresh = Date.distantPast

    var body: some View {
        HStack(spacing: 18) {
            tab("Ưu tiên", value: "priority", unread: store.unreadCount(priority: true))
            tab("Khác", value: "other", unread: store.unreadCount(priority: false))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 6)
        .onAppear { if store.priorityFilter == "all" { store.priorityFilter = "priority" } }
        .onDisappear { if !prioritySplit { store.priorityFilter = "all" } }
        // Picks up moves made on the phone without waiting for a restart; at most once a minute.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard Date().timeIntervalSince(lastRefresh) > 60 else { return }
            lastRefresh = Date(); store.reloadWorkspaceFeatures()
        }
    }

    private func tab(_ title: String, value: String, unread: Int) -> some View {
        let selected = store.priorityFilter == value
        return Button {
            withAnimation(reducedMotion ? nil : .snappy(duration: 0.22)) { store.priorityFilter = value }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
                    // The other tab shows a dot when it holds unread conversations.
                    if !selected && unread > 0 { Circle().fill(Color.red).frame(width: 7, height: 7) }
                }
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                ZStack {
                    Capsule().fill(.clear).frame(height: 2.5)
                    if selected { Capsule().fill(Color.accentColor).frame(height: 2.5).matchedGeometryEffect(id: "underline", in: underline) }
                }
            }
            .fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(unread > 0 && !selected ? "\(title), \(unread) hội thoại chưa đọc" : title)
    }
}
