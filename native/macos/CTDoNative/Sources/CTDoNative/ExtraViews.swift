import SwiftUI
import NativeBridge

struct StickerPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedPack: UInt64?
    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 115), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nhãn dán").font(.headline)
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm nhãn dán", text: $query).textFieldStyle(.plain)
            }
            .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 18).padding(.bottom, 14)
            HSplitView {
                List(store.stickerPacks, selection: $selectedPack) { pack in
                    Text(verbatim: pack.name).tag(pack.id)
                }
                .listStyle(.sidebar).frame(minWidth: 150, idealWidth: 170, maxWidth: 220)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.stickerItems) { sticker in
                            Button { store.sendSticker(sticker) } label: {
                                VStack(spacing: 4) {
                                    if let url = safeWebURL(sticker.imageURL) {
                                        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().controlSize(.small) }
                                            .frame(width: 78, height: 78)
                                    } else { Image(systemName: "face.smiling").font(.largeTitle).frame(width: 78, height: 78) }
                                    if let label = sticker.label, !label.isEmpty { Text(verbatim: label).font(.caption2).lineLimit(1) }
                                }
                                .padding(5).contentShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain).disabled(!store.canSend).help("Gửi nhãn dán")
                        }
                    }.padding(18)
                }
                .overlay {
                    if store.stickerItems.isEmpty {
                        if !store.busy.isDisjoint(with: ["sticker_pack", "search_stickers"]) { ProgressView() }
                        else { EmptyState("Chọn bộ nhãn dán", systemImage: "face.smiling", description: Text("Chọn một bộ hoặc tìm nhãn dán bạn muốn gửi.")) }
                    }
                }
            }
            if let error = store.error { Text(verbatim: error).font(.caption).foregroundStyle(.red).padding(12) }
        }
        .frame(width: 650, height: 480)
        .onValueChange(of: selectedPack) { _, category in
            guard let category else { return }
            query = ""
            store.send("sticker_pack", parameters: ["cate_id": .number(Double(category))])
        }
        .onValueChange(of: store.stickerPacks.map(\.id)) { _, ids in
            if selectedPack == nil { selectedPack = ids.first }
        }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.supports("search_stickers") else { return }
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            store.send("search_stickers", parameters: ["keyword": .string(query)])
        }
    }
}

struct ForwardMessageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: String?
    @State private var query = ""
    private var targets: [ThreadSnapshot] {
        store.threads.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chuyển tiếp tin nhắn").font(.title3.weight(.semibold))
            if let message = store.forwardMessage {
                Text(verbatim: message.text.isEmpty ? "Tin nhắn đính kèm" : message.text)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
            TextField("Tìm người hoặc nhóm", text: $query).textFieldStyle(.roundedBorder)
            List(targets, selection: $targetID) { thread in
                HStack { ThreadAvatar(thread: thread, size: 30); Text(verbatim: thread.name) }
                    .tag(thread.id)
            }.listStyle(.inset(alternatesRowBackgrounds: true))
            if let error = store.error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Chuyển tiếp") {
                    if let thread = store.threads.first(where: { $0.id == targetID }) { store.forward(to: thread) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetID == nil || store.busy.contains("forward_message"))
            }
        }
        .padding(20).frame(width: 440, height: 490)
    }
}

struct ScheduleSendView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3_600)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hẹn giờ gửi tin nhắn").font(.headline)
            DatePicker("Thời gian gửi", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Text("Ứng dụng cần đang mở và có kết nối khi đến giờ gửi.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Hủy") { dismiss() }
                Spacer()
                Button("Hẹn giờ") { store.schedule(at: date); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(!store.canSend || date <= Date())
            }
        }.padding(20).frame(width: 360)
    }
}

struct ScheduledMessagesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tin nhắn hẹn giờ").font(.headline)
                Spacer()
                Button { store.send("list_scheduled") } label: { Image(systemName: "arrow.clockwise") }.help("Tải lại")
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            List(store.scheduledMessages) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.hasError ? "exclamationmark.circle" : "clock").foregroundStyle(item.hasError ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: item.threadName).font(.headline)
                        Text(verbatim: item.text).font(.callout).lineLimit(4)
                        Text(item.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if item.hasError { Text("Chưa gửi được tin nhắn.").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 0)
                    if item.status == "pending" && store.supports("cancel_scheduled") {
                        Button("Hủy", role: .destructive) { store.send("cancel_scheduled", parameters: ["schedule_id": .number(Double(item.id))]) }
                    }
                }.padding(.vertical, 8)
            }
            .overlay {
                if store.scheduledMessages.isEmpty {
                    EmptyState("Chưa có tin nhắn hẹn giờ", systemImage: "clock",
                                           description: Text("Soạn tin nhắn và chọn biểu tượng đồng hồ để hẹn giờ gửi."))
                }
            }
            if let error = store.error { Text(verbatim: error).font(.caption).foregroundStyle(.red).padding(12) }
        }
        .frame(width: 560, height: 440).task { store.send("list_scheduled") }
    }
}
