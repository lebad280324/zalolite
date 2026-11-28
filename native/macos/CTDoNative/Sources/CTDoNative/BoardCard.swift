import SwiftUI
import NativeBridge

/// Official-account card (Zalo notices, `chat.list.action` and `chat.ecard`), read from the
/// `board` card the core sends: header parts with a large picture, then child rows.
struct BoardCardInfo: Equatable {
    struct Part: Equatable {
        let title: String
        let detail: String?
        let thumbnail: URL?
        let url: URL?
        let header: Bool
    }
    let parts: [Part]

    init?(_ message: MessageSnapshot) {
        guard message.card?["kind"]?.string == "board", case .array(let items)? = message.card?["parts"] else { return nil }
        let parts = items.compactMap { item -> Part? in
            guard let title = item["title"]?.string, !title.isEmpty else { return nil }
            let detail = item["desc"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Part(title: title, detail: detail?.isEmpty == false ? detail : nil,
                        thumbnail: safeWebURL(item["thumb"]?.string), url: safeWebURL(item["url"]?.string),
                        header: item["header"]?.bool ?? false)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }
}

struct BoardCard: View {
    let info: BoardCardInfo
    let time: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(info.parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Divider() }
                if part.header { header(part, last: index == info.parts.count - 1) } else { child(part) }
            }
            if !(info.parts.last?.header ?? false) {
                Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(width: 300, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
    }

    private func header(_ part: BoardCardInfo.Part, last: Bool) -> some View {
        Button { open(part) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let thumbnail = part.thumbnail {
                    picture(thumbnail).frame(width: 300, height: 168).clipped()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: part.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = part.detail {
                        Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if last {
                        Text(time, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(part.url == nil)
        .help(part.url?.absoluteString ?? "")
        .contextMenu { menu(part) }
    }

    private func child(_ part: BoardCardInfo.Part) -> some View {
        Button { open(part) } label: {
            HStack(spacing: 10) {
                Text(verbatim: part.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let thumbnail = part.thumbnail {
                    picture(thumbnail).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(part.url == nil)
        .help(part.url?.absoluteString ?? "")
        .contextMenu { menu(part) }
    }

    private func picture(_ url: URL) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else if phase.error != nil { Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.tertiary) }
                else { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder private func menu(_ part: BoardCardInfo.Part) -> some View {
        if let url = part.url {
            Button("Mở liên kết") { NSWorkspace.shared.open(url) }
            Button("Sao chép liên kết") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
        Button("Sao chép nội dung") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString([part.title, part.detail].compactMap { $0 }.joined(separator: "\n"), forType: .string)
        }
    }

    private func open(_ part: BoardCardInfo.Part) {
        if let url = part.url { NSWorkspace.shared.open(url) }
    }
}
