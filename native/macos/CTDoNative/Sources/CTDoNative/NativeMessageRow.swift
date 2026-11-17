import AppKit
import CoreText
import NativeBridge

/// Everything a transcript row needs to lay itself out and draw without SwiftUI.
struct NativeRowInput {
    let row: TranscriptRow
    let isGroup: Bool
    let selecting: Bool
    let selected: Bool
    let highlighted: Bool
    let showThumbnails: Bool
    let senderName: String
    let senderAvatar: String?
    let senderID: String
    let swipeOffset: CGFloat
    /// Text being searched in the conversation; its matches are marked in the caption.
    var searchTerm: String = ""

    var displayName: String { senderName.isEmpty ? row.message.senderName : senderName }
    /// Inputs that change geometry; selection, highlight and swipe only change drawing.
    @MainActor func sameLayout(as other: NativeRowInput) -> Bool {
        NativeTranscript.Coordinator.same(row, other.row) && isGroup == other.isGroup && selecting == other.selecting &&
            showThumbnails == other.showThumbnails && displayName == other.displayName
    }
}

struct NativeRowActions {
    var toggleSelection: (String) -> Void = { _ in }
    var reply: (MessageSnapshot) -> Void = { _ in }
    var quoteJump: (String) -> Void = { _ in }
    var profile: (NativeRowInput, NSView, NSRect) -> Void = { _, _, _ in }
}

/// Preserve the image's aspect ratio while anchoring its visible edge to the message column.
enum MessageMediaGeometry {
    static func fitted(_ size: CGSize, in bounds: CGRect, outgoing: Bool) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: outgoing ? bounds.maxX - width : bounds.minX,
                      y: bounds.maxY - height, width: width, height: height)
    }
}

enum NativeRowSupport {
    /// Animated stickers and file cards keep their SwiftUI rows; every other message draws natively.
    static func supports(_ message: MessageSnapshot) -> Bool {
        if message.messageType == "chat.sticker", safeWebURL(message.imageURL) != nil { return false }
        // Group notices are centred pills; reaction chips open the "who reacted" list.
        if message.messageType == "chat.system" || ReactionChips.hasReactions(message) { return false }
        // Voice notes, videos, call logs and bare links draw their own cards.
        if RichMedia.isRich(message) { return false }
        // Tagged names are set apart in colour, which the CoreText rows do not draw.
        if MessageTypography.hasMention(message.text) { return false }
        // Shared locations and link previews draw their cards in SwiftUI.
        if LocationPoint(message) != nil { return false }
        if MediaPresentation.showsLinkPreview(message) { return false }
        return MediaPresentation.fileURL(message) == nil
    }
}

// MARK: - Text

enum RowFont: Int {
    case body, time, sender, quoteName, quoteText, pill, reaction, label
    var font: NSFont {
        switch self {
        case .body: return .systemFont(ofSize: MessageTextSize.size(14))
        case .time: return .monospacedDigitSystemFont(ofSize: MessageTextSize.size(10), weight: .regular)
        case .sender: return .systemFont(ofSize: MessageTextSize.size(12.5), weight: .semibold)
        case .quoteName, .pill: return .systemFont(ofSize: MessageTextSize.size(12), weight: .semibold)
        case .quoteText, .label: return .systemFont(ofSize: MessageTextSize.size(12))
        case .reaction: return .systemFont(ofSize: MessageTextSize.size(10))
        }
    }
}

/// Lines broken for one width. The typesetter behind them is shared across widths.
final class TextBlock {
    struct Line {
        let line: CTLine
        let range: NSRange
        let top: CGFloat
        let height: CGFloat
        let baseline: CGFloat
        let width: CGFloat
    }
    let lines: [Line]
    let size: CGSize
    init(lines: [Line], size: CGSize) { self.lines = lines; self.size = size }
    var lastBaseline: CGFloat { lines.last?.baseline ?? 0 }
    var firstBaseline: CGFloat { lines.first?.baseline ?? 0 }
}

@MainActor enum RowText {
    static let strikeKey = NSAttributedString.Key("vn.ctdo.strike")
    private final class Prepared: NSObject {
        let text: NSAttributedString
        let setter: CTTypesetter
        init(_ text: NSAttributedString) { self.text = text; setter = CTTypesetterCreateWithAttributedString(text) }
    }
    private static let cache: NSCache<NSString, Prepared> = { let cache = NSCache<NSString, Prepared>(); cache.countLimit = 4000; return cache }()
    private static var lineHeights: [Int: CGFloat] = [:]
    private static let measurer = NSLayoutManager()
    private static let markup = try? NSRegularExpression(pattern: #"(\*\*|__|~~|\*)(.+?)\1"#)

    /// Forget prepared text and line heights after the reading size changes.
    static func reset() { cache.removeAllObjects(); lineHeights.removeAll() }

    static func lineHeight(_ font: RowFont) -> CGFloat {
        if let known = lineHeights[font.rawValue] { return known }
        let value = ceil(measurer.defaultLineHeight(for: font.font)); lineHeights[font.rawValue] = value; return value
    }

    private static func attributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    }

    /// Same flat markers as `MessageTypography.inline`, as an attributed string CoreText can draw.
    private static func styled(_ text: String) -> NSAttributedString {
        let base = RowFont.body.font
        guard let markup, text.contains("*") || text.contains("_") || text.contains("~") else { return NSAttributedString(string: text, attributes: attributes(base)) }
        let source = text as NSString
        let result = NSMutableAttributedString()
        var offset = 0
        for match in markup.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: offset, length: match.range.location - offset)), attributes: attributes(base)))
            var run = attributes(base)
            switch source.substring(with: match.range(at: 1)) {
            case "**": run[.font] = NSFont.systemFont(ofSize: MessageTextSize.size(14), weight: .bold)
            case "*": run[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            case "__": run[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "~~": run[strikeKey] = true
            default: break
            }
            result.append(NSAttributedString(string: source.substring(with: match.range(at: 2)), attributes: run))
            offset = match.range.location + match.range.length
        }
        result.append(NSAttributedString(string: source.substring(from: offset), attributes: attributes(base)))
        return result
    }

    private static func prepared(_ text: String, _ font: RowFont, markup: Bool) -> Prepared {
        let key = "\(font.rawValue)\(markup ? "m" : "p")\u{1}\(text)" as NSString
        if let known = cache.object(forKey: key) { return known }
        let value = Prepared(markup ? styled(text) : NSAttributedString(string: text, attributes: attributes(font.font)))
        cache.setObject(value, forKey: key)
        return value
    }

    /// The string a caption shows once its markers are removed; selection indexes refer to it.
    static func plain(_ text: String) -> NSString { prepared(text, .body, markup: true).text.string as NSString }

    static func block(_ text: String, _ font: RowFont, width: CGFloat, maxLines: Int = .max, markup: Bool = false, spacing: CGFloat = 0) -> TextBlock {
        let source = prepared(text, font, markup: markup)
        let length = source.text.length
        let limit = Double(max(8, width)), minimum = lineHeight(font)
        var lines: [TextBlock.Line] = []
        var start = 0, top: CGFloat = 0, widest: CGFloat = 0
        while start < length {
            var count = CTTypesetterSuggestLineBreak(source.setter, start, limit)
            if count <= 0 { count = length - start }
            var line = CTTypesetterCreateLine(source.setter, CFRange(location: start, length: count))
            if lines.count == maxLines - 1, start + count < length {
                // Last permitted line: show an ellipsis instead of silently dropping the rest.
                let rest = CTTypesetterCreateLine(source.setter, CFRange(location: start, length: length - start))
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes(font.font)))
                line = CTLineCreateTruncatedLine(rest, limit, .end, token) ?? line
                count = length - start
            }
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let used = max(0, advance - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            let height = max(minimum, ceil(ascent + descent + leading))
            let baseline = (top + (height - ascent - descent) / 2 + ascent).rounded()
            lines.append(.init(line: line, range: NSRange(location: start, length: count), top: top, height: height, baseline: baseline, width: used))
            widest = max(widest, used)
            top += height + spacing
            start += count
        }
        return TextBlock(lines: lines, size: CGSize(width: ceil(widest), height: lines.isEmpty ? minimum : top - spacing))
    }

    private static var times: [Int: String] = [:]
    static func time(_ message: MessageSnapshot) -> String {
        let minute = Int(message.timestamp / 60_000)
        if let known = times[minute] { return known }
        if times.count > 4000 { times.removeAll() }
        let value = message.date.formatted(.dateTime.hour().minute()); times[minute] = value; return value
    }
    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Hôm nay" }
        if Calendar.current.isDateInYesterday(date) { return "Hôm qua" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Layout

enum RowTone { case primary, secondary, accent, name, white, pill, time }

/// Pure geometry for one message at one width, in flipped (top-left) coordinates.
@MainActor final class MessageRowLayout {
    struct Placed { let block: TextBlock; var origin: CGPoint; let tone: RowTone; let moves: Bool }
    let input: NativeRowInput
    let width: CGFloat
    private(set) var height: CGFloat = 24
    private(set) var texts: [Placed] = []
    private(set) var pill: CGRect?
    private(set) var checkbox: CGRect?
    private(set) var avatar: CGRect?
    private(set) var bubble: CGRect = .zero
    private(set) var bare = false
    private(set) var radii: (tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) = (18, 18, 18, 18)
    private(set) var senderRect: CGRect?
    private(set) var quote: (rect: CGRect, bar: CGRect)?
    private(set) var photo: (rect: CGRect, url: URL, radius: CGFloat)?
    private(set) var link: (rect: CGRect, bar: CGRect, url: URL)?
    private(set) var caption: (rect: CGRect, block: TextBlock)?
    private(set) var timeRect: CGRect = .zero
    private(set) var timePill: CGRect?
    private(set) var reactions: CGRect?
    private(set) var rowBand: CGRect = .zero
    /// Smallest rectangle that contains everything drawn; the row's layer is only this large.
    private(set) var ink: CGRect = .zero
    private(set) var signature = 0

    var message: MessageSnapshot { input.row.message }

    init(_ input: NativeRowInput, width: CGFloat) {
        self.input = input; self.width = width
        build()
    }

    private func build() {
        let message = input.row.message, outgoing = message.isOutgoing, W = width
        var y: CGFloat = 1
        if input.row.showsTimestamp {
            y += 12
            let block = RowText.block(RowText.day(message.date), .pill, width: W - 60, maxLines: 1)
            let rect = CGRect(x: ((W - block.size.width - 22) / 2).rounded(), y: y, width: block.size.width + 22, height: block.size.height + 8)
            pill = rect
            texts.append(.init(block: block, origin: CGPoint(x: rect.minX + 11, y: rect.minY + 4), tone: .pill, moves: false))
            y += rect.height + 10
        }
        if input.row.startsRun { y += 6 }
        var left: CGFloat = 16
        let right = W - 16, rowTop = y
        if input.selecting { left += 32 }
        let bubbleLeft = outgoing ? left + 68 : left + 40
        let bubbleRight = outgoing ? right : right - 68
        let bubbleMax = max(44, min(min(480, max(100, (W - 32) * 0.78)), bubbleRight - bubbleLeft))
        bare = MediaPresentation.isBareImage(message) && input.showThumbnails
        let pad: CGFloat = bare ? 0 : 11
        let inner = bubbleMax - pad * 2

        // Content is measured from its own origin, then moved once the bubble position is known.
        var cy: CGFloat = 0, cw: CGFloat = 0, first = texts.count
        func gap() { if cy > 0 { cy += 5 } }
        if input.isGroup && !outgoing && input.row.startsRun && !bare {
            let block = RowText.block(input.displayName, .sender, width: inner, maxLines: 1)
            texts.append(.init(block: block, origin: CGPoint(x: 0, y: cy), tone: .name, moves: true))
            senderRect = CGRect(x: 0, y: cy, width: block.size.width, height: block.size.height)
            cy += block.size.height; cw = max(cw, block.size.width)
        }
        if let reply = message.replyToText, !reply.isEmpty {
            gap()
            let limit = inner - 23
            var ty = cy + 5, tw: CGFloat = 0
            if let name = message.replyToSender {
                let block = RowText.block(name, .quoteName, width: limit, maxLines: 1)
                texts.append(.init(block: block, origin: CGPoint(x: 17, y: ty), tone: .accent, moves: true))
                ty += block.size.height + 2; tw = block.size.width
            }
            let block = RowText.block(reply, .quoteText, width: limit, maxLines: 2)
            texts.append(.init(block: block, origin: CGPoint(x: 17, y: ty), tone: .secondary, moves: true))
            ty += block.size.height; tw = max(tw, block.size.width)
            let rect = CGRect(x: 0, y: cy, width: tw + 23, height: ty + 5 - cy)
            quote = (rect, CGRect(x: 6, y: cy + 5, width: 3, height: rect.height - 10))
            cy = rect.maxY; cw = max(cw, rect.width)
        }
        if input.showThumbnails, let url = MediaSource.photo(message) {
            gap()
            // Avatar, checkbox and opposite-side spacing also consume width in narrow windows.
            let side = min(280, max(1, inner))
            photo = (CGRect(x: 0, y: cy, width: side, height: (side * 0.75).rounded()), url, bare ? 16 : 10)
            cy += (side * 0.75).rounded(); cw = max(cw, side)
        }
        if MediaPresentation.showsLinkPreview(message), let url = safeWebURL(message.linkURL) {
            gap()
            let host = RowText.block(url.host ?? "Liên kết", .quoteName, width: inner - 11, maxLines: 1)
            let title = RowText.block(message.linkTitle ?? url.absoluteString, .quoteText, width: inner - 11, maxLines: 2)
            texts.append(.init(block: host, origin: CGPoint(x: 11, y: cy + 4), tone: .accent, moves: true))
            texts.append(.init(block: title, origin: CGPoint(x: 11, y: cy + 6 + host.size.height), tone: .primary, moves: true))
            let rect = CGRect(x: 0, y: cy, width: inner, height: host.size.height + title.size.height + 10)
            link = (rect, CGRect(x: 0, y: cy + 4, width: 3, height: rect.height - 8), url)
            cy = rect.maxY; cw = inner
        }
        let stamp = RowText.block(RowText.time(message), .time, width: 200, maxLines: 1)
        let stampWidth = stamp.size.width
        var words = MediaPresentation.caption(message)
        if !input.showThumbnails, message.imageURL != nil, words.isEmpty { words = "[Hình ảnh]" }
        var stampOrigin: CGPoint?
        if !words.isEmpty {
            gap()
            let block = RowText.block(words, .body, width: inner - 7 - stampWidth, markup: true, spacing: 1.5)
            texts.append(.init(block: block, origin: CGPoint(x: 0, y: cy), tone: .primary, moves: true))
            caption = (CGRect(x: 0, y: cy, width: block.size.width, height: block.size.height), block)
            stampOrigin = CGPoint(x: block.size.width + 7, y: cy + block.lastBaseline - stamp.firstBaseline)
            cy += block.size.height; cw = max(cw, block.size.width + 7 + stampWidth)
        }
        if message.text.isEmpty && message.imageURL == nil && message.fileURL == nil {
            gap()
            // The time sits after the label, as for a caption, so the two never overlap.
            let block = RowText.block("Loại tin này chưa hiển thị được — xem trên điện thoại", .label, width: inner - 7 - stampWidth, maxLines: 2)
            texts.append(.init(block: block, origin: CGPoint(x: 0, y: cy), tone: .secondary, moves: true))
            if stampOrigin == nil { stampOrigin = CGPoint(x: block.size.width + 7, y: cy + block.lastBaseline - stamp.firstBaseline) }
            cy += block.size.height; cw = max(cw, block.size.width + 7 + stampWidth)
        }
        if !bare && stampOrigin == nil { cw = max(cw, stampWidth - 4) }

        let bubbleWidth = min(bubbleMax, ceil(cw) + pad * 2), bubbleHeight = ceil(cy) + (bare ? 0 : 13)
        var blockHeight = bubbleHeight
        var chips: TextBlock?
        let labels = Self.reactionLabels(message)
        if !labels.isEmpty {
            let block = RowText.block(labels.joined(separator: " "), .reaction, width: bubbleMax - 28, maxLines: 1)
            chips = block
            blockHeight += block.size.height + 1
        }
        let showsAvatar = !outgoing && input.row.endsRun
        let bandHeight = max(blockHeight, showsAvatar ? 32 : 0)
        let origin = CGPoint(x: outgoing ? bubbleRight - bubbleWidth : bubbleLeft, y: y + bandHeight - blockHeight)
        bubble = CGRect(x: origin.x, y: origin.y, width: bubbleWidth, height: bubbleHeight)
        let dx = origin.x + pad, dy = origin.y + (bare ? 0 : 6)
        for index in first..<texts.count { texts[index].origin.x += dx; texts[index].origin.y += dy }
        senderRect = senderRect?.offsetBy(dx: dx, dy: dy)
        if let value = quote { quote = (value.rect.offsetBy(dx: dx, dy: dy), value.bar.offsetBy(dx: dx, dy: dy)) }
        if let value = photo { photo = (value.rect.offsetBy(dx: dx, dy: dy), value.url, value.radius) }
        if let value = link { link = (value.rect.offsetBy(dx: dx, dy: dy), value.bar.offsetBy(dx: dx, dy: dy), value.url) }
        if let value = caption { caption = (value.rect.offsetBy(dx: dx, dy: dy), value.block) }
        if let stampOrigin {
            timeRect = CGRect(x: stampOrigin.x + dx, y: stampOrigin.y + dy, width: stampWidth, height: stamp.size.height)
        } else if bare, let frame = photo?.rect {
            let box = CGRect(x: frame.maxX - 7 - stampWidth - 14, y: frame.maxY - 7 - stamp.size.height - 6, width: stampWidth + 14, height: stamp.size.height + 6)
            timePill = box; timeRect = CGRect(x: box.minX + 7, y: box.minY + 3, width: stampWidth, height: stamp.size.height)
        } else {
            timeRect = CGRect(x: bubble.maxX - 9 - stampWidth, y: bubble.maxY - 5 - stamp.size.height, width: stampWidth, height: stamp.size.height)
        }
        texts.append(.init(block: stamp, origin: timeRect.origin, tone: bare && caption == nil ? .white : .time, moves: true))
        first = texts.count
        if let chips {
            let size = CGSize(width: chips.size.width + 16, height: chips.size.height + 4)
            let rect = CGRect(x: outgoing ? bubble.maxX - 6 - size.width : bubble.minX + 6, y: bubble.maxY - 3, width: size.width, height: size.height)
            reactions = rect
            texts.append(.init(block: chips, origin: CGPoint(x: rect.minX + 8, y: rect.minY + 2), tone: .primary, moves: true))
        }
        if showsAvatar { avatar = CGRect(x: left, y: y + bandHeight - 32, width: 32, height: 32) }
        if input.selecting { checkbox = CGRect(x: 16, y: rowTop, width: 24, height: bandHeight) }
        rowBand = CGRect(x: 0, y: rowTop, width: W, height: bandHeight)
        let big: CGFloat = 18, small: CGFloat = 6, tail: CGFloat = input.row.endsRun ? 4 : small
        radii = outgoing ? (big, input.row.startsRun ? big : small, big, tail) : (input.row.startsRun ? big : small, big, tail, big)
        y += bandHeight + (input.row.endsRun ? 4 : 0) + 1
        height = max(24, ceil(y))

        var drawn = bubble
        for rect in [pill, checkbox, avatar, reactions, photo?.rect].compactMap({ $0 }) { drawn = drawn.union(rect) }
        if input.swipeOffset != 0 { drawn = drawn.union(CGRect(x: 0, y: rowBand.minY, width: W, height: rowBand.height)) }
        drawn = drawn.insetBy(dx: -4, dy: -4).integral.intersection(CGRect(x: 0, y: 0, width: W, height: height))
        ink = drawn

        // Positions relative to the ink rectangle: a bubble that only slides sideways needs no redraw.
        var hasher = Hasher()
        hasher.combine(drawn.width); hasher.combine(drawn.height)
        hasher.combine(bubble.minX - drawn.minX); hasher.combine(bubble.minY - drawn.minY); hasher.combine(bubble.width); hasher.combine(bubble.height)
        hasher.combine(pill.map { $0.minX - drawn.minX } ?? -1)
        hasher.combine(timeRect.minX - drawn.minX)
        hasher.combine(avatar.map { $0.minX - drawn.minX } ?? -1)
        for text in texts { hasher.combine(text.origin.x - drawn.minX); hasher.combine(text.origin.y - drawn.minY); hasher.combine(text.block.lines.count); hasher.combine(text.block.size.width) }
        signature = hasher.finalize()
    }

    static func reactionLabels(_ message: MessageSnapshot) -> [String] {
        switch message.reactions {
        case .array(let values): return values.compactMap(\.string)
        case .object(let values): return values.keys.sorted()
        default: return []
        }
    }
}

// MARK: - View

/// Draws one message with Core Graphics and CoreText. It owns no layout engine and no hosting view.
@MainActor final class NativeMessageView: NSView {
    private(set) var layout: MessageRowLayout?
    private var actions = NativeRowActions()
    private var photo: NSImage?
    private var photoURL: URL?
    private var photoFailed = false
    private var photoTask: Task<Void, Never>?
    private var face: NSImage?
    private var faceURL: URL?
    private var faceTask: Task<Void, Never>?
    private var selection: NSRange?
    private var selectionAnchor = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { selection != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The row redraws only when its layout or state changes, never because the table moved or resized it.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        // Wide-gamut displays default to 64-bit backing stores, which cost several times more to fill and upload.
        layer.contentsFormat = .RGBA8Uint
        return layer
    }

    func apply(_ next: MessageRowLayout, actions: NativeRowActions, originX: CGFloat) {
        self.actions = actions
        let previous = layout
        layout = next
        // The layer covers the ink only, while drawing and hit-testing keep row coordinates.
        let target = next.ink.offsetBy(dx: -originX, dy: 0)
        // A new size or bounds origin shifts the cached bitmap and repaints only the exposed strip,
        // which left slices of old bubbles behind while the window was resized. Repaint all of it.
        let geometryChanged = frame.size != target.size || bounds.origin != next.ink.origin
        if frame != target { frame = target }
        if bounds.origin != next.ink.origin { setBoundsOrigin(next.ink.origin) }
        let sameMessage = previous.map { NativeTranscript.Coordinator.same($0.input.row, next.input.row) } ?? false
        if !sameMessage {
            selection = nil
            let message = next.message
            setAccessibilityLabel([next.input.displayName, MediaPresentation.caption(message), RowText.time(message)].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        loadPhoto(next.photo?.url)
        loadFace(next.avatar == nil ? nil : safeWebURL(next.input.senderAvatar))
        let unchanged = sameMessage && previous?.signature == next.signature && previous?.input.selected == next.input.selected &&
            previous?.input.highlighted == next.input.highlighted && previous?.input.swipeOffset == next.input.swipeOffset &&
            previous?.input.displayName == next.input.displayName && previous?.input.senderAvatar == next.input.senderAvatar &&
            previous?.input.senderID == next.input.senderID && previous?.input.searchTerm == next.input.searchTerm
        if !unchanged || geometryChanged { needsDisplay = true; if TranscriptDiagnostics.enabled { TranscriptDiagnostics.applyRedraws += 1 } }
    }

    private func loadPhoto(_ url: URL?) {
        guard url != photoURL else { return }
        photoTask?.cancel(); photoURL = url; photo = nil; photoFailed = false
        guard let url else { return }
        if let ready = PhotoCache.shared.cached(url) { photo = ready; return }
        photoTask = Task { [weak self] in
            var image = try? await PhotoCache.shared.image(url)
            if image == nil {
                // One more attempt later; the failure must not stick until the app restarts.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                image = try? await PhotoCache.shared.image(url)
            }
            guard !Task.isCancelled, let self, self.photoURL == url else { return }
            self.photo = image; self.photoFailed = image == nil; self.needsDisplay = true
        }
    }

    private func loadFace(_ url: URL?) {
        guard url != faceURL else { return }
        faceTask?.cancel(); faceURL = url; face = nil
        guard let url else { return }
        if let ready = PhotoCache.shared.cached(url) { face = ready; return }
        faceTask = Task { [weak self] in
            let image = try? await PhotoCache.shared.image(url)
            guard !Task.isCancelled, let self, self.faceURL == url else { return }
            self.face = image; self.needsDisplay = true
        }
    }

    private var drawnDark: Bool?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Reparenting a reused cell also lands here; only a real light/dark change needs new pixels.
        guard drawnDark != dark else { return }
        needsDisplay = true
        if TranscriptDiagnostics.enabled { TranscriptDiagnostics.appearanceRedraws += 1 }
    }

    // MARK: Drawing

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink]

    private func color(_ tone: RowTone, _ layout: MessageRowLayout) -> NSColor {
        let outgoing = layout.message.isOutgoing && !layout.bare
        switch tone {
        case .primary: return outgoing ? .white : .labelColor
        case .secondary: return outgoing ? NSColor.white.withAlphaComponent(0.78) : .secondaryLabelColor
        case .accent: return outgoing ? .white : .controlAccentColor
        case .white: return .white
        case .pill: return NSColor.labelColor.withAlphaComponent(0.75)
        // Quieter than secondary text, still legible on either bubble.
        case .time: return outgoing ? NSColor.white.withAlphaComponent(0.62) : NSColor.labelColor.withAlphaComponent(0.4)
        case .name:
            let key = layout.input.senderID.isEmpty ? layout.input.displayName : layout.input.senderID
            return Self.palette[Int(key.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31 &+ $1.value) % 10_007 }) % Self.palette.count]
        }
    }

    private func bubblePath(_ rect: CGRect, _ radii: (tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat)) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(radii.tl, limit), tr = min(radii.tr, limit), bl = min(radii.bl, limit), br = min(radii.br, limit)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }

    private func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let value = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: value, cornerHeight: value, transform: nil)
    }

    private func draw(_ block: TextBlock, at origin: CGPoint, color: NSColor, in context: CGContext, dirty: CGRect) {
        context.setFillColor(color.cgColor); context.setStrokeColor(color.cgColor)
        for line in block.lines {
            let top = origin.y + line.top
            if top > dirty.maxY || top + line.height < dirty.minY { continue }
            context.textPosition = CGPoint(x: origin.x, y: origin.y + line.baseline)
            CTLineDraw(line.line, context)
            // CoreText draws underlines but not strikethroughs.
            for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                guard (CTRunGetAttributes(run) as NSDictionary)[RowText.strikeKey] != nil else { continue }
                let range = CTRunGetStringRange(run)
                let from = CTLineGetOffsetForStringIndex(line.line, range.location, nil), to = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
                context.fill(CGRect(x: origin.x + from, y: origin.y + line.baseline - 4.5, width: to - from, height: 1))
            }
        }
    }

    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let fitted = CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(image: NSImage, in rect: CGRect, fill: Bool, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = fill ? max(rect.width / image.size.width, rect.height / image.size.height) : min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.interpolationQuality = .medium
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let context = NSGraphicsContext.current?.cgContext else { return }
        let started = TranscriptDiagnostics.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer { if TranscriptDiagnostics.enabled { TranscriptDiagnostics.drawn += 1; TranscriptDiagnostics.drawNanos += DispatchTime.now().uptimeNanoseconds - started } }
        let message = layout.message, outgoing = message.isOutgoing, dark = dark
        drawnDark = dark
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let incoming: NSColor = dark ? NSColor(white: 0.17, alpha: 1) : .white

        if let pill = layout.pill {
            context.addPath(rounded(pill, pill.height / 2))
            context.setFillColor((dark ? NSColor(white: 0.16, alpha: 0.78) : NSColor(white: 1, alpha: 0.78)).cgColor)
            context.fillPath()
        }
        if let box = layout.checkbox {
            let mark = CGRect(x: box.midX - 8, y: box.midY - 8, width: 16, height: 16)
            context.addPath(rounded(mark, 8))
            if layout.input.selected {
                context.setFillColor(NSColor.controlAccentColor.cgColor); context.fillPath()
                symbol("checkmark", size: 9, weight: .bold, color: .white, in: mark)
            } else {
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor); context.setLineWidth(1.5); context.strokePath()
            }
        }
        for text in layout.texts where !text.moves { draw(text.block, at: text.origin, color: color(text.tone, layout), in: context, dirty: dirtyRect) }

        let offset = layout.input.swipeOffset
        if abs(offset) > 8 {
            let reached = abs(offset) >= SwipeReplyTracker.threshold
            let spot = CGRect(x: offset >= 0 ? 6 : bounds.width - 30, y: layout.rowBand.midY - 12, width: 24, height: 24)
            symbol("arrowshape.turn.up.left.fill", size: 14, weight: .semibold,
                   color: (reached ? NSColor.controlAccentColor : .secondaryLabelColor).withAlphaComponent(min(1, abs(offset) / SwipeReplyTracker.threshold)), in: spot)
        }
        context.saveGState()
        context.translateBy(x: offset, y: 0)
        let dirty = dirtyRect.offsetBy(dx: -offset, dy: 0)

        if let frame = layout.avatar {
            context.saveGState()
            context.addEllipse(in: frame); context.clip()
            if let face { draw(image: face, in: frame, fill: true, context: context) }
            else {
                let colors = [NSColor(red: 0.69, green: 0.72, blue: 0.83, alpha: 1).cgColor, NSColor(red: 0.50, green: 0.54, blue: 0.68, alpha: 1).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: frame.midX, y: frame.minY), end: CGPoint(x: frame.midX, y: frame.maxY), options: [])
                }
                let initials = layout.input.displayName.split(separator: " ").suffix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
                if initials.isEmpty || initials.contains(where: { $0.isNumber }) {
                    symbol("person.fill", size: 14, weight: .regular, color: .white, in: frame.offsetBy(dx: 0, dy: 2))
                } else {
                    let font = NSFont.systemFont(ofSize: 12.2, weight: .medium)
                    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12.2) } ?? font
                    let text = NSAttributedString(string: initials, attributes: [.font: rounded, .foregroundColor: NSColor.white])
                    let size = text.size()
                    text.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
                }
            }
            context.restoreGState()
        }

        if !layout.bare, layout.bubble.intersects(dirty.insetBy(dx: -4, dy: -4)) {
            let path = bubblePath(layout.bubble, layout.radii)
            // A one-point soft edge below the bubble; a blurred shadow costs a convolution per row.
            context.addPath(bubblePath(layout.bubble.offsetBy(dx: 0, dy: 1), layout.radii))
            context.setFillColor(NSColor.black.withAlphaComponent(0.07).cgColor); context.fillPath()
            context.addPath(path)
            context.setFillColor((outgoing ? NSColor.controlAccentColor : incoming).cgColor)
            context.fillPath()
            if outgoing {
                let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
                let top = accent.blended(withFraction: 0.16, of: .white) ?? accent
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, accent.cgColor] as CFArray, locations: nil) {
                    context.saveGState()
                    context.addPath(path); context.clip()
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: layout.bubble.minY), end: CGPoint(x: 0, y: layout.bubble.maxY), options: [])
                    context.restoreGState()
                }
            }
        }
        if let quote = layout.quote {
            context.addPath(rounded(quote.rect, 7))
            context.setFillColor((outgoing ? NSColor.white.withAlphaComponent(0.18) : NSColor.controlAccentColor.withAlphaComponent(0.08)).cgColor)
            context.fillPath()
            context.addPath(rounded(quote.bar, 1.5))
            context.setFillColor((outgoing ? NSColor.white : NSColor.controlAccentColor).cgColor); context.fillPath()
        }
        if let link = layout.link {
            context.addPath(rounded(link.bar, 1.5))
            context.setFillColor((outgoing ? NSColor.white : NSColor.controlAccentColor).cgColor); context.fillPath()
        }
        let photoRect = layout.photo.map { frame in
            photo.map { MessageMediaGeometry.fitted($0.size, in: frame.rect, outgoing: outgoing) } ?? frame.rect
        }
        let stampOffset: CGFloat = layout.bare && layout.caption == nil
            ? (photoRect?.maxX ?? 0) - (layout.photo?.rect.maxX ?? 0) : 0
        if let frame = layout.photo, frame.rect.intersects(dirty) {
            context.saveGState()
            context.addPath(rounded(photoRect ?? frame.rect, frame.radius)); context.clip()
            if let photo { draw(image: photo, in: photoRect ?? frame.rect, fill: false, context: context) }
            else {
                context.setFillColor(NSColor.labelColor.withAlphaComponent(0.055).cgColor); context.fill(frame.rect)
                symbol(photoFailed ? "photo.badge.exclamationmark" : "photo", size: 20, weight: .regular, color: .secondaryLabelColor, in: frame.rect)
            }
            context.restoreGState()
        }
        if let pill = layout.timePill {
            context.addPath(rounded(pill.offsetBy(dx:stampOffset,dy:0), pill.height / 2))
            context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor); context.fillPath()
        }
        if let chips = layout.reactions {
            context.addPath(rounded(chips.insetBy(dx: -0.5, dy: -0.5).offsetBy(dx: 0, dy: 0.5), chips.height / 2))
            context.setFillColor(NSColor.black.withAlphaComponent(0.09).cgColor); context.fillPath()
            context.addPath(rounded(chips, chips.height / 2)); context.setFillColor(incoming.cgColor); context.fillPath()
        }
        if !layout.input.searchTerm.isEmpty, let caption = layout.caption {
            // Search matches, marked like Zalo's yellow highlight.
            let plain = RowText.plain(MediaPresentation.caption(layout.message))
            var from = 0
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(outgoing ? 0.75 : 0.55).cgColor)
            while from < plain.length {
                let found = plain.range(of: layout.input.searchTerm, options: [.caseInsensitive, .diacriticInsensitive],
                                        range: NSRange(location: from, length: plain.length - from))
                guard found.location != NSNotFound, found.length > 0 else { break }
                for line in caption.block.lines {
                    let shared = NSIntersectionRange(found, line.range)
                    guard shared.length > 0 else { continue }
                    let a = CTLineGetOffsetForStringIndex(line.line, shared.location, nil), b = CTLineGetOffsetForStringIndex(line.line, shared.location + shared.length, nil)
                    context.addPath(rounded(CGRect(x: caption.rect.minX + a - 1, y: caption.rect.minY + line.top + 1, width: max(2, b - a) + 2, height: line.height - 2), 3))
                    context.fillPath()
                }
                from = found.location + found.length
            }
        }
        if let selection, let caption = layout.caption {
            context.setFillColor((outgoing ? NSColor.white.withAlphaComponent(0.32) : NSColor.selectedTextBackgroundColor).cgColor)
            for line in caption.block.lines {
                let shared = NSIntersectionRange(selection, line.range)
                guard shared.length > 0 else { continue }
                let from = CTLineGetOffsetForStringIndex(line.line, shared.location, nil), to = CTLineGetOffsetForStringIndex(line.line, shared.location + shared.length, nil)
                context.fill(CGRect(x: caption.rect.minX + from, y: caption.rect.minY + line.top, width: max(2, to - from), height: line.height))
            }
        }
        for text in layout.texts where text.moves {
            let tone = text.tone == .primary && layout.reactions != nil && text.origin.y >= layout.bubble.maxY - 3 ? NSColor.labelColor : color(text.tone, layout)
            draw(text.block, at: text.origin == layout.timeRect.origin ? CGPoint(x:text.origin.x+stampOffset,y:text.origin.y) : text.origin, color: tone, in: context, dirty: dirty)
        }
        if layout.input.highlighted {
            let path = layout.bare ? rounded((photoRect ?? layout.bubble).insetBy(dx: 1, dy: 1), 16) : bubblePath(layout.bubble.insetBy(dx: 1, dy: 1), layout.radii)
            context.addPath(path); context.setStrokeColor(NSColor.systemOrange.cgColor); context.setLineWidth(2); context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: Interaction

    private func index(at point: CGPoint, in caption: (rect: CGRect, block: TextBlock)) -> Int {
        let y = point.y - caption.rect.minY
        guard let first = caption.block.lines.first, let last = caption.block.lines.last else { return 0 }
        if y < first.top { return first.range.location }
        let line = caption.block.lines.first { y < $0.top + $0.height } ?? last
        if y > last.top + last.height { return NSMaxRange(last.range) }
        let found = CTLineGetStringIndexForPosition(line.line, CGPoint(x: point.x - caption.rect.minX, y: 0))
        return found == kCFNotFound ? line.range.location : max(line.range.location, min(NSMaxRange(line.range), found))
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= layout.input.swipeOffset
        let message = layout.message
        if let box = layout.checkbox, box.insetBy(dx: -8, dy: 0).contains(point) { actions.toggleSelection(message.id); return }
        if let avatar = layout.avatar, avatar.contains(point) { actions.profile(layout.input, self, avatar); return }
        if let sender = layout.senderRect, layout.input.isGroup, sender.contains(point) { actions.profile(layout.input, self, sender); return }
        if let quote = layout.quote, quote.rect.contains(point), let original = message.replyToID { actions.quoteJump(original); return }
        if let photo = layout.photo, photo.rect.contains(point) { NotificationCenter.default.post(name: .openImageViewer, object: photo.url); return }
        if let link = layout.link, link.rect.contains(point) { NSWorkspace.shared.open(link.url); return }
        if event.clickCount == 2 { clearSelection(); actions.reply(message); return }
        guard let caption = layout.caption, caption.rect.insetBy(dx: -6, dy: -4).contains(point) else { clearSelection(); return }
        selectionAnchor = index(at: point, in: caption)
        if selection != nil { selection = nil; needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let layout, let caption = layout.caption else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= layout.input.swipeOffset
        let current = index(at: point, in: caption)
        let next = NSRange(location: min(selectionAnchor, current), length: abs(current - selectionAnchor))
        if next.length > 0, selection != next {
            selection = next; needsDisplay = true
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }
    }

    private func clearSelection() { if selection != nil { selection = nil; needsDisplay = true } }
    override func resignFirstResponder() -> Bool { clearSelection(); return true }

    @objc func copy(_ sender: Any?) {
        guard let layout, let selection, selection.length > 0 else { return }
        var words = MediaPresentation.caption(layout.message)
        if !layout.input.showThumbnails, layout.message.imageURL != nil, words.isEmpty { words = "[Hình ảnh]" }
        let plain = RowText.plain(words)
        guard NSMaxRange(selection) <= plain.length else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain.substring(with: selection), forType: .string)
    }
}

final class NativeMessageCell: NSTableCellView {
    let content: NativeMessageView
    override init(frame: NSRect) {
        content = MainActor.assumeIsolated { NativeMessageView(frame: NSRect(origin: .zero, size: frame.size)) }
        super.init(frame: frame)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var layout: MessageRowLayout?
    private var actions = NativeRowActions()
    /// Repaints the whole message, used once a live resize ends.
    func repaint() { content.needsDisplay = true }

    func apply(_ layout: MessageRowLayout, actions: NativeRowActions) {
        self.layout = layout; self.actions = actions
        // The table insets its column inside the row; the message is laid out in row coordinates.
        content.apply(layout, actions: actions, originX: frame.minX)
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin.x != frame.minX
        super.setFrameOrigin(newOrigin)
        if moved, let layout { content.apply(layout, actions: actions, originX: frame.minX) }
    }
}

/// Rows carry no drawing of their own; without this every row would own a full-width backing store.
final class TranscriptRowView: NSTableRowView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// Lets event monitors ask which message is under the pointer without per-row tracking areas.
@MainActor enum TranscriptPointer {
    static weak var active: NativeTranscript.Coordinator?
    static func messageID() -> String? { active?.messageUnderPointer() }
}
