import AppKit
import SwiftUI

/// Colour of your own message bubbles (Cài đặt → Giao diện). "Xanh dịu" is the default: the system
/// accent gradient read as glaring on dark backgrounds.
enum OutgoingBubble: String, CaseIterable, Identifiable {
    case soft, system, light, gray
    static let key = "nativeOutgoingBubble"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .soft: return "Xanh dịu"
        case .system: return "Màu hệ thống"
        case .light: return "Xanh nhạt"
        case .gray: return "Xám"
        }
    }

    /// UserDefaults keeps the value in memory, so reading it while drawing is cheap.
    static var current: OutgoingBubble { OutgoingBubble(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .soft }

    @MainActor static func set(_ value: OutgoingBubble) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        RowText.reset()
        // Same relayout path as a text size change.
        NotificationCenter.default.post(name: .messageTextSizeChanged, object: nil)
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light }
    }
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    var fill: NSColor {
        switch self {
        case .soft: return Self.dynamic(dark: Self.hex(0x2B5FD9), light: Self.hex(0x1A6DF0))
        case .system: return .controlAccentColor
        case .light: return Self.dynamic(dark: Self.hex(0x1F3A5F), light: Self.hex(0xDCEBFF))
        case .gray: return Self.dynamic(dark: Self.hex(0x48484A), light: Self.hex(0xE3E5EA))
        }
    }

    /// Text and marks drawn on the bubble; the light styles use dark text in light mode.
    var text: NSColor {
        switch self {
        case .soft, .system: return .white
        case .light: return Self.dynamic(dark: Self.hex(0xDCE9FF), light: Self.hex(0x0C2E66))
        case .gray: return Self.dynamic(dark: .white, light: Self.hex(0x1C1C1E))
        }
    }

    /// Only the system style keeps the gentle top-to-bottom sheen.
    var gradient: Bool { self == .system }

    var fillColor: Color { Color(nsColor: fill) }
    var textColor: Color { Color(nsColor: text) }
    /// The bubble as a SwiftUI fill, with the system style's gradient.
    var fillStyle: AnyShapeStyle { gradient ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(fillColor) }
}

/// Settings control with a live preview of both bubbles.
struct OutgoingBubblePicker: View {
    @AppStorage(OutgoingBubble.key) private var stored = OutgoingBubble.soft.rawValue
    @Environment(\.colorScheme) private var scheme
    private var style: OutgoingBubble { OutgoingBubble(rawValue: stored) ?? .soft }

    var body: some View {
        Picker("Màu bong bóng của bạn", selection: Binding(get: { style }, set: { stored = $0.rawValue; OutgoingBubble.set($0) })) {
            ForEach(OutgoingBubble.allCases) { option in
                HStack(spacing: 6) {
                    Circle().fill(option.fillColor).frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
                    Text(option.label)
                }
                .tag(option)
            }
        }
        VStack(spacing: 6) {
            HStack {
                Text("Tin của người khác")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(scheme == .dark ? Color(white: 0.17) : .white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer()
            }
            HStack {
                Spacer()
                Text("Tin bạn gửi trông như thế này")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(style.fillStyle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(style.textColor)
            }
        }
        .font(.system(size: MessageTextSize.size(14)))
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.2), value: stored)
    }
}
