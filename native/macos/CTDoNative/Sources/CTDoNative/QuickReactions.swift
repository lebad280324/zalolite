import AppKit
import SwiftUI
import NativeBridge

/// The hovered message for the quick reaction button, in the conversation column's coordinates
/// (origin top-left). `anchor` is the bubble edge facing the free side, or the pointer when the
/// row has no measured bubble.
struct QuickReactTarget: Equatable {
    let id: String
    let outgoing: Bool
    let anchorX: CGFloat
    let bottom: CGFloat
}

/// Tracks the message under the pointer so a reaction button can sit beside it, as in Zalo.
@MainActor
final class QuickReactionMonitor: ObservableObject {
    @Published private(set) var target: QuickReactTarget?
    private var monitor: Any?

    func install(column: @escaping () -> CGRect, enabled: @escaping () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .mouseExited]) { [weak self] event in
            nonisolated(unsafe) let captured = event
            MainActor.assumeIsolated {
                guard let window = captured.window, window.identifier?.rawValue == "main" else { return }
                if !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
                self?.update(window: window, column: column(), enabled: enabled())
            }
            return event
        }
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.acceptsMouseMovedEvents = true
    }

    func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; target = nil }
    func hide() { target = nil }

    private func update(window: NSWindow, column: CGRect, enabled: Bool) {
        guard enabled, let hover = TranscriptPointer.hover(), let height = window.contentView?.bounds.height else {
            if target != nil { target = nil }
            return
        }
        // AppKit window points grow upwards; SwiftUI column coordinates grow downwards.
        func columnPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - column.minX, y: height - point.y - column.minY) }
        let x: CGFloat
        if hover.bubble {
            x = columnPoint(CGPoint(x: hover.outgoing ? hover.rect.minX : hover.rect.maxX, y: 0)).x
        } else if target?.id == hover.id, let current = target {
            x = current.anchorX
        } else {
            x = columnPoint(window.mouseLocationOutsideOfEventStream).x + (hover.outgoing ? -24 : 24)
        }
        let bottom = columnPoint(CGPoint(x: 0, y: hover.rect.minY)).y
        let next = QuickReactTarget(id: hover.id, outgoing: hover.outgoing, anchorX: x, bottom: bottom)
        if next != target { target = next }
    }
}

/// A small 👍 beside the hovered bubble: a click sends 👍, hovering it opens Zalo's six reactions.
struct QuickReactionBar: View {
    let mine: String?
    let react: (String) -> Void
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    static let reactions = ["❤️", "👍", "😆", "😮", "😢", "😡"]

    var body: some View {
        HStack(spacing: 2) {
            if expanded {
                ForEach(Self.reactions, id: \.self) { emoji in
                    Button { react(emoji) } label: {
                        Text(emoji).font(.system(size: 20))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(mine == emoji ? Color.accentColor.opacity(0.22) : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(QuickReactionButtonStyle())
                    .help(mine == emoji ? "Bỏ cảm xúc" : "Thả \(emoji)")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            } else {
                Button { react("👍") } label: {
                    Image(systemName: mine == nil ? "hand.thumbsup" : "hand.thumbsup.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(mine == nil ? Color.secondary : Color.accentColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Thích (rê chuột để chọn cảm xúc khác)")
            }
        }
        .padding(expanded ? 4 : 0)
        .nativeGlass(expanded ? 22 : 14)
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .onHover { inside in
            withAnimation(reducedMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75)) { expanded = inside }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thả cảm xúc nhanh")
    }
}

private struct QuickReactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.85 : 1)
    }
}
