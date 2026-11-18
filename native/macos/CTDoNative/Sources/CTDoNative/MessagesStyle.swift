import AppKit
import SwiftUI
import NativeBridge

// MARK: - Avatars

/// Thread avatar: own image, otherwise a composite of up to four members, otherwise a monogram.
struct ThreadAvatar: View {
    let thread: ThreadSnapshot
    var size: CGFloat = 40
    var body: some View {
        if safeWebURL(thread.avatar) == nil && thread.isGroup && !thread.avatarMembers.isEmpty {
            CompositeAvatar(members: Array(thread.avatarMembers.prefix(4)), total: thread.memberTotal, size: size)
                .accessibilityHidden(true)
        } else {
            AvatarView(name: thread.name, url: thread.avatar, size: size, group: thread.isGroup)
        }
    }
}

/// Small member discs packed inside one circle, as group avatars are drawn on macOS.
struct CompositeAvatar: View {
    let members: [AvatarMember]
    let total: Int?
    let size: CGFloat
    private var extra: Int { max(0, (total ?? members.count) - members.count) }
    var body: some View {
        let count = min(members.count, 4)
        let small = count <= 2 ? size * 0.58 : size * 0.5
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            ForEach(Array(members.prefix(count).enumerated()), id: \.offset) { index, member in
                if index == 3 && extra > 0 {
                    Circle().fill(Color(nsColor: .tertiaryLabelColor))
                        .overlay { Text("+\(min(extra + 1, 99))").font(.system(size: small * 0.38, weight: .semibold)).foregroundStyle(.white) }
                        .frame(width: small, height: small)
                        .offset(offset(index, count: count, small: small))
                } else {
                    AvatarView(name: member.name, url: member.avatar, size: small)
                        .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1, size * 0.025)) }
                        .offset(offset(index, count: count, small: small))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    private func offset(_ index: Int, count: Int, small: CGFloat) -> CGSize {
        let d = (size - small) / 2
        switch count {
        case 1: return .zero
        case 2: return index == 0 ? CGSize(width: -d * 0.8, height: -d * 0.55) : CGSize(width: d * 0.8, height: d * 0.55)
        case 3: return [CGSize(width: 0, height: -d * 0.9), CGSize(width: -d * 0.9, height: d * 0.6), CGSize(width: d * 0.9, height: d * 0.6)][index]
        default: return [CGSize(width: -d, height: -d), CGSize(width: d, height: -d), CGSize(width: -d, height: d), CGSize(width: d, height: d)][index]
        }
    }
}

// MARK: - Conversation header

/// Avatar over a glass name capsule; the whole control opens the details panel.
struct ConversationHeader: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    var availableWidth:CGFloat=480
    var body: some View {
        Button { store.showingInspector.toggle() } label: {
            VStack(spacing: -5) {
                ThreadAvatar(thread: thread, size: 38).zIndex(1)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                HStack(spacing: 3) {
                    Text(verbatim: thread.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
                .frame(width:min(availableWidth,max(210,CGFloat(thread.name.count)*8.2+44)))
                // Drawn explicitly so the capsule reads the same with or without toolbar glass.
                .nativeGlass(18)
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Thông tin cuộc trò chuyện (⌘I)")
        .accessibilityLabel("Thông tin về \(thread.name)")
    }
}

// MARK: - Emoji picker

/// Emoji grouped by Unicode block; names come from Unicode so search needs no bundled data.
enum EmojiCatalog {
    struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        let emoji: [String]
    }

    private static func scalars(_ ranges: [ClosedRange<UInt32>]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { continue }
                let text = String(Character(scalar))
                if seen.insert(text).inserted { out.append(text) }
            }
        }
        return out
    }

    private static let flagRegions = ["VN", "US", "GB", "JP", "KR", "CN", "TW", "HK", "SG", "TH", "LA", "KH", "MY", "ID", "PH", "IN",
                                      "AU", "NZ", "CA", "FR", "DE", "IT", "ES", "PT", "NL", "BE", "CH", "SE", "NO", "DK", "FI", "PL",
                                      "CZ", "RU", "UA", "TR", "AE", "SA", "IL", "EG", "ZA", "NG", "BR", "AR", "MX", "CL", "CO", "PE"]

    static let categories: [Category] = [
        Category(id: "smileys", title: "Mặt cười", icon: "face.smiling",
                 emoji: scalars([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1FAE0...0x1FAE8])),
        Category(id: "people", title: "Người và cử chỉ", icon: "hand.wave",
                 emoji: scalars([0x1F440...0x1F487, 0x1F90C...0x1F90F, 0x1F918...0x1F91F, 0x1F930...0x1F93E, 0x1F9B0...0x1F9B9, 0x1F9CD...0x1F9DF, 0x1FAF0...0x1FAF8])),
        Category(id: "nature", title: "Động vật và thiên nhiên", icon: "pawprint",
                 emoji: scalars([0x1F400...0x1F43F, 0x1F330...0x1F344, 0x1F980...0x1F9AE, 0x1FAB0...0x1FABD, 0x1F300...0x1F320])),
        Category(id: "food", title: "Đồ ăn và thức uống", icon: "fork.knife",
                 emoji: scalars([0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADB])),
        Category(id: "activity", title: "Hoạt động", icon: "soccerball",
                 emoji: scalars([0x1F380...0x1F393, 0x1F3A0...0x1F3D3, 0x26BD...0x26BE, 0x1F93A...0x1F94F, 0x1F6F7...0x1F6FC])),
        Category(id: "travel", title: "Du lịch và địa điểm", icon: "car",
                 emoji: scalars([0x1F680...0x1F6F6, 0x1F3D4...0x1F3F0, 0x1F5FA...0x1F5FF])),
        Category(id: "objects", title: "Đồ vật", icon: "lightbulb",
                 emoji: scalars([0x1F4A1...0x1F4FF, 0x1F50A...0x1F53D, 0x1F9F0...0x1F9FF, 0x1FA70...0x1FAAF, 0x231A...0x23F3])),
        Category(id: "symbols", title: "Biểu tượng", icon: "heart",
                 emoji: scalars([0x1F493...0x1F4A0, 0x1F5A4...0x1F5A4, 0x1F9E1...0x1F9E1, 0x1FA75...0x1FA77, 0x2648...0x2653,
                                 0x2705...0x2705, 0x274C...0x274E, 0x2753...0x2757, 0x2795...0x2797, 0x1F534...0x1F539, 0x1F7E0...0x1F7EB, 0x2B50...0x2B55])),
        Category(id: "flags", title: "Cờ", icon: "flag",
                 emoji: flagRegions.map { code in
                     String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
                 }),
    ]

    /// Common Vietnamese words mapped to Unicode name fragments.
    private static let vietnamese: [String: [String]] = [
        "cười": ["GRIN", "SMIL", "LAUGH", "JOY"], "vui": ["SMIL", "GRIN", "PARTY"], "buồn": ["SAD", "DISAPPOINTED", "PENSIVE", "CRY"],
        "khóc": ["CRY", "TEAR", "SOB"], "tim": ["HEART"], "yêu": ["HEART", "LOVE", "KISS"], "hôn": ["KISS"],
        "giận": ["ANGRY", "POUTING", "RAGE"], "thích": ["THUMBS UP", "HEART"], "ok": ["OK HAND", "THUMBS UP"],
        "cảm ơn": ["FOLDED HANDS"], "chúc mừng": ["PARTY", "CONFETTI", "TADA"], "ngạc nhiên": ["ASTONISHED", "OPEN MOUTH", "FLUSHED"],
        "ngủ": ["SLEEP", "ZZZ"], "mèo": ["CAT"], "chó": ["DOG"], "hoa": ["FLOWER", "BLOSSOM", "ROSE", "TULIP"],
        "lửa": ["FIRE"], "sao": ["STAR"], "mặt trời": ["SUN"], "mưa": ["RAIN", "UMBRELLA"], "cà phê": ["HOT BEVERAGE"],
        "bánh": ["CAKE", "BREAD"], "bia": ["BEER"], "tiền": ["MONEY", "DOLLAR"], "xe": ["CAR", "AUTOMOBILE", "BUS"],
        "nhà": ["HOUSE"], "điện thoại": ["MOBILE PHONE"], "máy tính": ["COMPUTER", "LAPTOP"], "quà": ["GIFT"], "vỗ tay": ["CLAPPING"],
        "cờ": ["FLAG"], "việt nam": ["🇻🇳"],
    ]

    static func search(_ query: String) -> [String] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        let fragments = vietnamese.filter { $0.key.hasPrefix(text) || text.hasPrefix($0.key) }.flatMap(\.value) + [text.uppercased()]
        var seen = Set<String>()
        return categories.flatMap(\.emoji).filter { emoji in
            guard !seen.contains(emoji) else { return false }
            let name = emoji.unicodeScalars.compactMap(\.properties.name).joined(separator: " ")
            let hit = fragments.contains { fragment in fragment == emoji || name.contains(fragment) }
            if hit { seen.insert(emoji) }
            return hit
        }
    }
}

/// Inserts text at the composer's caret; the text view observes this notification.
extension Notification.Name {
    static let composerInsertText = Notification.Name("vn.ctdo.native.composerInsertText")
}

struct EmojiPickerPopover: View {
    @AppStorage("nativeRecentEmoji") private var recentStorage = ""
    @State private var query = ""
    @State private var section = "recent"
    @FocusState private var searching: Bool
    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 4), count: 6)
    private var recent: [String] { recentStorage.split(separator: " ").map(String.init) }
    private var defaultRecent: [String] { ["😂", "❤️", "👍", "😍", "😭", "🥰", "😊", "🙏", "😆", "🔥", "😅", "🥲", "😘", "👌", "😢", "🎉"] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm kiếm", text: $query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay { Capsule().strokeBorder(searching ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2) }
            .padding(12)
            ScrollViewReader { reader in
                ScrollView {
                    // One lazy level of pre-chunked rows: nested lazy grids, pinned material headers and
                    // per-cell tooltips made scrolling stutter.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !query.isEmpty {
                            let hits = EmojiCatalog.search(query)
                            if hits.isEmpty {
                                Text("Không tìm thấy biểu tượng").font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                            } else { grid(hits) }
                        } else {
                            header("Dùng gần đây").id("recent")
                            grid(recent.isEmpty ? defaultRecent : recent)
                            ForEach(EmojiCatalog.categories) { category in
                                header(category.title).id(category.id)
                                grid(category.emoji)
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                .onValueChange(of: section) { _, target in withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(target, anchor: .top) } }
            }
            Divider()
            HStack(spacing: 0) {
                tab("recent", "clock")
                ForEach(EmojiCatalog.categories) { tab($0.id, $0.icon) }
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 340, height: 440)
        .onAppear { searching = true }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 2).padding(.horizontal, 4)
    }

    @ViewBuilder private func grid(_ items: [String]) -> some View {
        let rows = stride(from: 0, to: items.count, by: 6).map { Array(items[$0..<min($0 + 6, items.count)]) }
        ForEach(rows, id: \.first) { row in
            HStack(spacing: 4) {
                ForEach(row, id: \.self) { emoji in
                    Text(emoji).font(.system(size: 34)).frame(width: 48, height: 46)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(emoji) }
                }
            }
            // Each row is rasterised once, so scrolling moves bitmaps instead of re-laying out glyphs.
            .drawingGroup()
        }
    }

    private func tab(_ id: String, _ icon: String) -> some View {
        Button { query = ""; section = id } label: {
            Image(systemName: icon).font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(section == id ? Color.primary : Color.secondary)
                .background(section == id ? Color.primary.opacity(0.1) : .clear, in: Circle())
        }.buttonStyle(.plain)
    }

    private func choose(_ emoji: String) {
        // The picker stays open: insert at the caret without moving keyboard focus.
        NotificationCenter.default.post(name: .composerInsertText, object: emoji, userInfo: ["keepFocus": true])
        var items = recent.filter { $0 != emoji }
        items.insert(emoji, at: 0)
        recentStorage = items.prefix(24).joined(separator: " ")
    }
}

private struct EmojiCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

// MARK: - Swipe to reply

/// Tracks a horizontal two-finger trackpad swipe over the hovered message.
@MainActor
final class SwipeReplyTracker: ObservableObject {
    @Published var messageID: String?
    @Published var offset: CGFloat = 0
    private var monitor: Any?
    private var swallowMomentum = false
    /// Finger travel before resistance; the bubble follows with a soft rubber band, never a hard stop.
    private var travel: CGFloat = 0
    static let threshold: CGFloat = 60

    func install(hovered: @escaping () -> String?, onReply: @escaping (String) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on the main thread; only a consume decision crosses back.
            nonisolated(unsafe) let captured = event
            let consumed = MainActor.assumeIsolated { self.handle(captured, hovered: hovered, onReply: onReply) }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; messageID = nil; offset = 0
    }

    private func handle(_ event: NSEvent, hovered: () -> String?, onReply: (String) -> Void) -> Bool {
        // Momentum after a tracked swipe must not scroll the transcript sideways.
        if event.momentumPhase != [] { return swallowMomentum }
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began {
            swallowMomentum = false
            messageID = nil; travel = 0
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.4, let id = hovered() { messageID = id }
        }
        guard let id = messageID else { return false }
        switch event.phase {
        case .began, .changed:
            // Fingers moving right pull the bubble right, as on iPhone.
            let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            travel += delta
            let next = (travel >= 0 ? 1 : -1) * 140 * (1 - exp(-abs(travel) / 140))
            if abs(next) >= Self.threshold && abs(offset) < Self.threshold {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            offset = next
            return true
        case .ended, .cancelled:
            if abs(offset) >= Self.threshold { onReply(id) }
            swallowMomentum = true
            travel = 0
            withAnimation(.interpolatingSpring(stiffness: 260, damping: 24)) { offset = 0 }
            messageID = nil
            return true
        default:
            return true
        }
    }
}

// MARK: - Chat background

enum ChatBackground {
    static let presets: [(id: String, title: String, colors: [Color])] = [
        ("dawn", "Bình minh", [Color(red: 1.0, green: 0.86, blue: 0.80), Color(red: 0.86, green: 0.82, blue: 1.0)]),
        ("ocean", "Đại dương", [Color(red: 0.76, green: 0.89, blue: 1.0), Color(red: 0.80, green: 0.97, blue: 0.93)]),
        ("forest", "Rừng", [Color(red: 0.84, green: 0.95, blue: 0.82), Color(red: 0.96, green: 0.95, blue: 0.80)]),
        ("dusk", "Hoàng hôn", [Color(red: 0.36, green: 0.27, blue: 0.56), Color(red: 0.95, green: 0.55, blue: 0.47)]),
        ("night", "Đêm", [Color(red: 0.10, green: 0.13, blue: 0.24), Color(red: 0.22, green: 0.18, blue: 0.36)]),
        ("graphite", "Than chì", [Color(white: 0.86), Color(white: 0.72)]),
    ]

    /// Copies a chosen picture into the app's own folder so the background survives the original moving.
    /// `folder` keeps the chat wallpaper and the lock screen picture apart; each holds one picture.
    static func importImage(from source: URL, folder name: String = "backgrounds") throws -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ctdozlite-native/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let target = folder.appendingPathComponent("background-\(UUID().uuidString.prefix(8)).jpg")
        try jpeg.write(to: target, options: .atomic)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where old != target {
            try? FileManager.default.removeItem(at: old)
        }
        return target
    }
}

/// Transcript background chosen in Settings > Giao diện.
struct ChatBackgroundView: View {
    /// Nil before a conversation is chosen; the chosen wallpaper still shows behind the workspace.
    let thread: ThreadSnapshot?
    @AppStorage("nativeChatBackground") private var choice = "none"
    @AppStorage("nativeChatBackgroundImage") private var imagePath = ""
    @AppStorage("nativeChatBackgroundDim") private var dim = 0.15
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            switch choice {
            case "avatar":
                if let thread, let url = safeWebURL(thread.avatar) ?? safeWebURL(thread.avatarMembers.first?.avatar) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 60).opacity(scheme == .dark ? 0.45 : 0.35)
                }
            case "image":
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                (scheme == .dark ? Color.black : Color.white).opacity(dim)
            default:
                if let preset = ChatBackground.presets.first(where: { "preset:" + $0.id == choice }) {
                    LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(scheme == .dark && !["dusk", "night"].contains(preset.id) ? 0.35 : 1)
                }
            }
        }
        .clipped().ignoresSafeArea().allowsHitTesting(false)
        .task(id: imagePath + choice) {
            guard choice == "image", !imagePath.isEmpty else { image = nil; return }
            let path = imagePath
            image = await Task.detached { NSImage(contentsOfFile: path) }.value
        }
    }
}
