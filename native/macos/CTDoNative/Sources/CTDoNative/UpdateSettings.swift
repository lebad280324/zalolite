import SwiftUI
import AppKit

/// Settings page for the installed version, the latest release and automatic checks.
struct SoftwareUpdateSection: View {
    @ObservedObject private var updater = SoftwareUpdater.shared
    @AppStorage(SoftwareUpdater.autoCheckKey) private var autoCheck = true

    var body: some View {
        Section("Phiên bản") {
            LabeledContent("Phiên bản đang dùng", value: updater.currentVersion)
            status
            HStack {
                Button("Kiểm tra cập nhật") { updater.check() }.disabled(updater.busy)
                if let lastCheck = updater.lastCheck {
                    Text("Lần kiểm tra gần nhất: \(lastCheck.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let release = shownRelease, !release.notes.isEmpty {
            Section("Có gì mới trong \(release.version)") {
                ScrollView {
                    Text(notes(release.notes)).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 220)
                if let page = release.pageURL { Link("Xem bản phát hành trên GitHub", destination: page).font(.callout) }
            }
        }
        Section("Tự động") {
            Toggle("Tự động kiểm tra bản mới mỗi ngày", isOn: $autoCheck)
            Text("Zalolite hỏi trang Releases của dự án trên GitHub, không gửi tài khoản hay dữ liệu chat. Gói tải về được đối chiếu mã SHA-256 và chữ ký trước khi cài; ứng dụng tự mở lại sau khi cập nhật.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shownRelease: UpdateRelease? {
        switch updater.phase {
        case .available(let release), .downloading(let release, _), .installing(let release), .manual(let release, _): return release
        default: return nil
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang kiểm tra…").foregroundStyle(.secondary) }
        case .upToDate:
            Label("Zalolite đã là bản mới nhất.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let release):
            HStack {
                Label("Có bản mới \(release.version)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Spacer()
                if release.archiveSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(release.archiveSize), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                Button("Tải và cài đặt") { updater.install(release) }.buttonStyle(.borderedProminent)
            }
        case .downloading(_, let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Button("Hủy") { updater.cancel() }
            }
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang kiểm tra và cài đặt… Zalolite sẽ tự mở lại.").foregroundStyle(.secondary) }
        case .manual(_, let app):
            VStack(alignment: .leading, spacing: 6) {
                Label("Đã tải và kiểm tra xong bản mới.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Zalolite không có quyền ghi vào thư mục đang chứa ứng dụng. Thoát Zalolite rồi kéo bản mới trong Finder vào thư mục Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
            }
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Thử lại") { updater.check() }
            }
        }
    }

    private func notes(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// "Kiểm tra cập nhật…" in the app menu; names the new version once a check has found one.
struct UpdateMenuItem: View {
    @ObservedObject private var updater = SoftwareUpdater.shared
    let openPage: () -> Void
    var body: some View {
        Button(updater.available.map { "Cài bản cập nhật \($0.version)…" } ?? "Kiểm tra cập nhật…") {
            if updater.available == nil { updater.check() }
            openPage()
        }
    }
}
