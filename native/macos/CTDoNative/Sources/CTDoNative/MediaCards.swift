import SwiftUI
import AppKit
import AVKit
import LinkPresentation
import NativeBridge

// MARK: - Recognising rich messages

/// Where to load a message's photo or video from: the copy imported from a Zalo export when there
/// is one (works offline and after Zalo's link expires), otherwise Zalo's web address.
enum MediaSource {
    /// Existence is remembered per path, so rows do not touch the disk on every layout pass.
    nonisolated(unsafe) private static let present = NSCache<NSString, NSNumber>()
    static func local(_ message: MessageSnapshot) -> URL? {
        guard let path = message.localPath, path.hasPrefix("/") else { return nil }
        let key = path as NSString
        let exists = present.object(forKey: key)?.boolValue ?? {
            let found = FileManager.default.fileExists(atPath: path)
            present.setObject(NSNumber(value: found), forKey: key)
            return found
        }()
        return exists ? URL(fileURLWithPath: path) : nil
    }
    static func photo(_ message: MessageSnapshot) -> URL? {
        guard message.imageURL != nil || message.messageType == "chat.photo" else { return nil }
        return local(message) ?? safeWebURL(message.imageURL)
    }
}

/// Media kinds the core stores as plain links or text; recognised by URL shape and Zalo's wording.
enum RichMedia {
    private static let voiceExtensions: Set<String> = ["aac", "amr", "m4a", "opus", "ogg"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "3gp"]

    /// A message whose whole text is one web address and that carries no other media.
    static func plainURL(_ message: MessageSnapshot) -> URL? {
        guard message.linkURL == nil, message.imageURL == nil, message.fileURL == nil else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("http://") || text.hasPrefix("https://"), !text.contains(where: \.isWhitespace) else { return nil }
        return safeWebURL(text)
    }

    /// Voice notes arrive as `.aac` files on Zalo's voice hosts.
    static func voiceURL(_ message: MessageSnapshot) -> URL? {
        guard let url = safeWebURL(message.fileURL ?? message.linkURL) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let ext = url.pathExtension.lowercased()
        return host.contains("voice") || (voiceExtensions.contains(ext) && host.hasSuffix("zdn.vn")) ? url : nil
    }

    /// Videos are stored as files on Zalo's video hosts, with a still frame as the thumbnail.
    static func video(_ message: MessageSnapshot) -> (url: URL, thumbnail: URL?)? {
        guard voiceURL(message) == nil, let url = safeWebURL(message.fileURL ?? message.linkURL) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let isVideo = message.messageType == "chat.video.msg" || host.hasPrefix("video-") || host.contains(".video")
            || videoExtensions.contains(url.pathExtension.lowercased())
        return isVideo ? (MediaSource.local(message) ?? url, safeWebURL(message.linkThumbnail) ?? safeWebURL(message.imageURL)) : nil
    }

    static func isRich(_ message: MessageSnapshot) -> Bool {
        plainURL(message) != nil || voiceURL(message) != nil || video(message) != nil || CallRecord(message) != nil
            || ContactCardInfo(message) != nil
    }
}

/// A call log line ("📞 Cuộc gọi nhỡ", "📹 Cuộc gọi video đi (42s)", "Cuộc gọi").
struct CallRecord {
    enum Kind { case outgoing, incoming, missed, declined, unknown }
    let kind: Kind
    let video: Bool
    let seconds: Int?

    init?(_ message: MessageSnapshot) {
        if message.card?["kind"]?.string == "call" {
            let missed = message.card?["missed"]?.bool ?? false
            let seconds = Int(message.card?["duration"]?.number ?? 0)
            video = message.card?["video"]?.bool ?? false
            kind = missed || (seconds == 0 && !message.isOutgoing) ? .missed : message.isOutgoing ? .outgoing : .incoming
            self.seconds = seconds
            return
        }
        guard message.imageURL == nil, message.fileURL == nil, message.linkURL == nil else { return nil }
        var text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["📞", "📹"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        guard text.hasPrefix("Cuộc gọi"), text.count <= 48, !text.contains("\n") else { return nil }
        let rest = text.dropFirst("Cuộc gọi".count).trimmingCharacters(in: .whitespaces)
        let known = ["", "thoại/video", "nhỡ", "video nhỡ", "thoại nhỡ", "đi", "đến", "video đi", "video đến", "thoại đi", "thoại đến"]
        let head = rest.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard known.contains(head) else { return nil }
        video = message.text.hasPrefix("📹") || head.contains("video") && head != "thoại/video"
        if rest.contains("Đã từ chối") { kind = .declined }
        else if head.contains("nhỡ") { kind = .missed }
        else if head.hasSuffix("đi") { kind = .outgoing }
        else if head.hasSuffix("đến") { kind = .incoming }
        else { kind = message.isOutgoing ? .outgoing : .incoming }
        if let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: "s"), open < close,
           let value = Int(rest[rest.index(after: open)..<close]) { seconds = value } else { seconds = nil }
    }

    var title: String {
        switch kind {
        case .missed: return video ? "Cuộc gọi video nhỡ" : "Cuộc gọi nhỡ"
        case .declined: return "Đã từ chối cuộc gọi"
        case .outgoing: return video ? "Cuộc gọi video đi" : "Cuộc gọi đi"
        case .incoming: return video ? "Cuộc gọi video đến" : "Cuộc gọi đến"
        case .unknown: return "Cuộc gọi"
        }
    }
    /// Second line of the card: how long the call lasted, or why it did not connect.
    /// The call type is already in the icon and title, so it is not repeated here.
    var detail: String {
        switch kind {
        case .missed: return "Không trả lời"
        case .declined: return "Đã từ chối"
        default:
            guard let seconds, seconds > 0 else { return "Không kết nối" }
            if seconds >= 3600 { return "\(seconds / 3600) giờ \(seconds % 3600 / 60) phút" }
            if seconds >= 60 { return seconds % 60 == 0 ? "\(seconds / 60) phút" : "\(seconds / 60) phút \(seconds % 60) giây" }
            return "\(seconds) giây"
        }
    }
    var connected: Bool { kind != .missed && kind != .declined && (seconds ?? 0) > 0 }
}

// MARK: - Link previews

/// Title and image for a link, read with LinkPresentation as Messages does, cached per URL.
@MainActor final class LinkPreviewStore: ObservableObject {
    static let shared = LinkPreviewStore()
    struct Preview { var title: String?; var image: NSImage? }
    @Published private(set) var previews: [URL: Preview] = [:]
    private var loading: Set<URL> = []

    func preview(_ url: URL) -> Preview? { previews[url] }

    func load(_ url: URL) {
        guard previews[url] == nil, !loading.contains(url), UserDefaults.standard.object(forKey: "nativeLinkPreviews") as? Bool ?? true else { return }
        loading.insert(url)
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.startFetchingMetadata(for: url) { metadata, _ in
            let title = metadata?.title
            let imageProvider = metadata?.imageProvider
            guard let imageProvider, imageProvider.canLoadObject(ofClass: NSImage.self) else {
                Task { @MainActor in self.finish(url, Preview(title: title, image: nil)) }
                return
            }
            _ = imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                Task { @MainActor in self.finish(url, Preview(title: title, image: image)) }
            }
        }
    }

    private func finish(_ url: URL, _ preview: Preview) {
        loading.remove(url)
        previews[url] = preview
    }
}

/// Zalo-style link card: a large picture when the page has one, then site, title and address.
struct RichLinkCard: View {
    let url: URL
    let title: String?
    let thumbnail: URL?
    let time: Date?
    /// Zalo's page description; used as the heading when the title is only the address.
    var summary: String? = nil
    @ObservedObject private var previews = LinkPreviewStore.shared
    @State private var hovering = false

    private var preview: LinkPreviewStore.Preview? { previews.preview(url) }
    private var host: String { (url.host ?? "Liên kết").replacingOccurrences(of: "www.", with: "") }
    private var isMap: Bool { host.contains("maps.") || host.hasPrefix("goo.gl") || url.path.hasPrefix("/maps") }
    private var heading: String {
        for candidate in [title, summary, preview?.title] {
            let value = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != url.absoluteString { return value }
        }
        return isMap ? "Vị trí trên Google Maps" : host
    }

    var body: some View {
        Group {
            if preview?.image != nil || thumbnail != nil { large } else { LinkCard(url: url, title: heading, thumbnail: nil, time: time) }
        }
        .onAppear { if title == nil || thumbnail == nil { previews.load(url) } }
    }

    private var large: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color.primary.opacity(0.06)
                    if let image = preview?.image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else if let thumbnail {
                        AsyncImage(url: thumbnail) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else if phase.error != nil { Image(systemName: "link").font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.accentColor.opacity(0.6)) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .frame(width: 300, height: 168).clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: isMap ? "mappin.and.ellipse" : "safari").font(.system(size: 11))
                        Text(verbatim: host).font(.system(size: 11.5)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let time { Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().opacity(0.82) }
                    }.foregroundStyle(Color.accentColor)
                    Text(verbatim: heading).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty, detail != heading {
                        Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(width: 300, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.45 : 0.15), lineWidth: 1) }
            .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
        .contextMenu {
            Button("Mở liên kết") { NSWorkspace.shared.open(url) }
            Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }
}

// MARK: - Voice notes

/// One voice note playing at a time across the transcript.
@MainActor final class VoicePlayback: ObservableObject {
    static let shared = VoicePlayback()
    @Published private(set) var current: URL?
    @Published private(set) var progress: Double = 0
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: URL) {
        if current == url, let player {
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
            objectWillChange.send(); return
        }
        stop()
        let player = AVPlayer(url: url)
        self.player = player; current = url; progress = 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let duration = self.player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
                self.progress = min(1, time.seconds / duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        player.play()
    }

    func isPlaying(_ url: URL) -> Bool { current == url && player?.timeControlStatus != .paused }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil; endObserver = nil
        player?.pause(); player = nil; current = nil; progress = 0
    }
}

/// Voice note bubble: play button, a waveform that fills as it plays, and the length.
struct VoiceCard: View {
    let url: URL
    let outgoing: Bool
    let time: Date
    @ObservedObject private var playback = VoicePlayback.shared
    @State private var duration: Double?
    @Environment(\.colorScheme) private var scheme

    /// Decorative bars, stable per clip; Zalo does not send the real envelope.
    private var bars: [CGFloat] {
        var seed = UInt64(truncatingIfNeeded: url.absoluteString.hashValue)
        return (0..<28).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.25 + CGFloat((seed >> 33) % 75) / 100
        }
    }
    private var playing: Bool { playback.isPlaying(url) }
    private var progress: Double { playback.current == url ? playback.progress : 0 }
    private var tint: Color { outgoing ? OutgoingBubble.current.textColor : .accentColor }

    var body: some View {
        HStack(spacing: 11) {
            Button { playback.toggle(url) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(outgoing ? OutgoingBubble.current.fillColor : .white)
                    .frame(width: 38, height: 38).background(outgoing ? OutgoingBubble.current.textColor : Color.accentColor, in: Circle())
                    .replaceSymbolTransition()
            }.buttonStyle(.plain).help(playing ? "Tạm dừng" : "Phát tin nhắn thoại")
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                        Capsule().fill(Double(index) / Double(bars.count) < progress ? tint : tint.opacity(0.35))
                            .frame(width: 3, height: 22 * height)
                    }
                }.frame(height: 24)
                HStack {
                    Text(durationText).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Spacer()
                    Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().opacity(0.82)
                }.foregroundStyle(outgoing ? OutgoingBubble.current.textColor.opacity(0.85) : .secondary)
            }.frame(width: 150)
        }
        .padding(.leading, 9).padding(.trailing, 13).padding(.vertical, 9)
        .background(outgoing ? OutgoingBubble.current.fillStyle : AnyShapeStyle(scheme == .dark ? Color(white: 0.17) : .white),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .animation(.linear(duration: 0.05), value: progress)
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            if let value = try? await asset.load(.duration).seconds, value.isFinite, value > 0 { duration = value }
        }
        .contextMenu {
            Button("Mở bằng ứng dụng khác") { NSWorkspace.shared.open(url) }
            Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
        .accessibilityElement(children: .combine).accessibilityLabel("Tin nhắn thoại \(durationText)")
    }

    private var durationText: String {
        guard let duration else { return "Tin nhắn thoại" }
        let shown = playback.current == url ? duration * (1 - progress) : duration
        let seconds = Int(shown.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Video

/// Video message: still frame with length and a play button; plays in a window-sized sheet.
/// A video plays right in the conversation, like Messenger: a click starts it in place with
/// inline controls; the expand button still opens the large player.
struct VideoCard: View {
    /// Asks open transcripts to measure their rows again, without the card observing the store.
    static let remeasure = Notification.Name("vn.ctdo.native.transcriptRemeasure")
    /// Learnt aspects outlive the card, so a re-measured row gets the right height at once.
    @MainActor static var aspects: [URL: CGFloat] = [:]
    let url: URL
    let thumbnail: URL?
    let time: Date
    @State private var duration: Double?
    /// Width over height, from the video track; portrait clips (TikTok, Reels) stay portrait.
    @State private var aspect: CGFloat?
    private var knownAspect: CGFloat? { aspect ?? Self.aspects[url] }
    @State private var player: AVPlayer?
    @State private var expanded = false
    @State private var hovering = false

    private var size: CGSize {
        let width: CGFloat = 240
        guard let aspect = knownAspect, aspect > 0 else { return CGSize(width: width, height: 260) }
        return CGSize(width: width, height: min(380, max(140, width / aspect)))
    }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerView(player: player, inline: true)
            } else {
                Button { start() } label: {
                    ZStack {
                        if let thumbnail {
                            AsyncImage(url: thumbnail) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small).tint(.white) }
                        }
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                            .scaleEffect(hovering ? 1.08 : 1)
                    }
                    .frame(width: size.width, height: size.height).clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Phát video")
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if player == nil, let duration {
                Text(format(duration)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.45), in: Capsule()).padding(9)
            }
        }
        .overlay(alignment: .topTrailing) {
            if player != nil || hovering {
                Button { player?.pause(); expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(8).help("Mở cửa sổ lớn")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if player == nil {
                Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.4), in: Capsule()).padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            if let value = try? await asset.load(.duration).seconds, value.isFinite, value > 0 { duration = value }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let shown = natural.applying(transform)
                if abs(shown.height) > 0 {
                    let value = abs(shown.width) / abs(shown.height)
                    let first = Self.aspects[url] == nil
                    Self.aspects[url] = value
                    aspect = value
                    // The row was measured at the default height; measure it again once.
                    if first { NotificationCenter.default.post(name: Self.remeasure, object: nil) }
                }
            }
        }
        // Scrolled away or the conversation changed: stop instead of playing unseen.
        .onDisappear { player?.pause() }
        .sheet(isPresented: $expanded) { VideoSheet(url: url) { expanded = false } }
        .contextMenu {
            Button(player == nil ? "Phát video" : "Tạm dừng") { if let player { player.pause() } else { start() } }
            Button("Mở cửa sổ lớn") { player?.pause(); expanded = true }
            Button("Mở bằng ứng dụng khác") { NSWorkspace.shared.open(url) }
            Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }

    private func start() {
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    private func format(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct VideoSheet: View {
    let url: URL
    let close: () -> Void
    @State private var player: AVPlayer?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Video").font(.headline)
                Spacer()
                Button("Mở bằng ứng dụng khác") { NSWorkspace.shared.open(url) }
                Button("Đóng") { player?.pause(); close() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            PlayerView(player: player).frame(minWidth: 640, minHeight: 400)
        }
        .frame(width: 760, height: 520)
        .onAppear { let player = AVPlayer(url: url); self.player = player; player.play() }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Calls

/// Call log card with the call type, length and a call-back button, as on Zalo.
struct CallCard: View {
    @EnvironmentObject private var store: AppStore
    let record: CallRecord
    let outgoing: Bool
    let time: Date
    @Environment(\.colorScheme) private var scheme

    private var missed: Bool { record.kind == .missed || record.kind == .declined }
    private var icon: String {
        switch record.kind {
        case .missed, .declined: return record.video ? "video.slash.fill" : "phone.down.fill"
        case .outgoing: return record.video ? "video.fill" : "phone.arrow.up.right.fill"
        default: return record.video ? "video.fill" : "phone.arrow.down.left.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(missed ? Color.red : outgoing ? Color.accentColor : Color.green)
                    .frame(width: 36, height: 36)
                    .background((missed ? Color.red : outgoing ? Color.accentColor : Color.green).opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(missed ? Color.red : .primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if record.connected { Image(systemName: "clock").font(.system(size: 10, weight: .medium)) }
                        Text(record.detail).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(time, format: .dateTime.hour().minute()).monospacedDigit().foregroundStyle(.tertiary)
                    }.font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            if store.supports("start_call") {
                Divider().opacity(0.6)
                Button { store.startCall(video: record.video) } label: {
                    Text("Gọi lại").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .frame(width: 230)
        .background(scheme == .dark ? Color(white: 0.17) : .white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }
}

/// AppKit's player view. SwiftUI's `VideoPlayer` aborts at launch of this SwiftPM-built app
/// (`_AVKit_SwiftUI` superclass metadata missing; crash reports 2026-11-12 13:53 and 14:06).
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?
    /// Inside a message: compact controls under the picture, no full screen button.
    var inline = false
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = inline ? .inline : .floating
        view.showsFullScreenToggleButton = !inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
