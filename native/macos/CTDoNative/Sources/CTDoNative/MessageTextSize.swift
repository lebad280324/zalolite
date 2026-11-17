import AppKit
import SwiftUI

extension Notification.Name {
    static let messageTextSizeChanged = Notification.Name("vn.ctdo.messageTextSizeChanged")
}

/// Reading size for message text, chosen in Cài đặt → Giao diện. Every message font (CoreText
/// rows, SwiftUI captions, quotes, times and the composer) is multiplied by `scale`.
enum MessageTextSize {
    static let key = "nativeMessageTextScale"
    static let choices: [(label: String, scale: Double)] = [("Nhỏ", 0.9), ("Vừa", 1.0), ("Lớn", 1.15), ("Rất lớn", 1.3)]

    /// UserDefaults keeps the value in memory, so reading it per font is cheap and thread-safe.
    static var scale: CGFloat { clamped(UserDefaults.standard.object(forKey: key) as? Double ?? 1) }

    static func size(_ base: CGFloat) -> CGFloat { (base * scale * 2).rounded() / 2 }

    /// Store a new scale, drop cached text layouts and ask open transcripts to lay out again.
    @MainActor static func set(_ value: Double) {
        let next = clamped(value)
        UserDefaults.standard.set(Double(next), forKey: key)
        RowText.reset()
        NotificationCenter.default.post(name: .messageTextSizeChanged, object: nil)
    }

    private static func clamped(_ value: Double) -> CGFloat { CGFloat(min(1.5, max(0.8, value))) }
}

/// Settings control with a live preview bubble.
struct MessageTextSizePicker: View {
    @AppStorage(MessageTextSize.key) private var stored = 1.0

    var body: some View {
        Picker("Cỡ chữ tin nhắn", selection: Binding(get: { stored }, set: { stored = $0; MessageTextSize.set($0) })) {
            ForEach(MessageTextSize.choices, id: \.scale) { Text($0.label).tag($0.scale) }
        }
        .pickerStyle(.segmented)
        HStack {
            Spacer()
            Text("Xin chào! Cỡ chữ này dùng cho tin nhắn và ô soạn.")
                .font(.system(size: 14 * stored))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
        .animation(.snappy(duration: 0.2), value: stored)
    }
}
