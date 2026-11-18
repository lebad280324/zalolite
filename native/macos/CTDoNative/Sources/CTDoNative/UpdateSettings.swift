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
            Text("Zalolite hỏi trang Releases của dự án trên GitHub, không gửi tài khoản hay dữ liệu chat. Gói tải về được đối chiếu mã SHA-256 và chữ ký trước khi cài. Tải xong, bạn chọn Khởi động lại ngay hoặc Để sau (bản mới được cài khi thoát Zalolite).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shownRelease: UpdateRelease? {
        switch updater.phase {
        case .available(let release), .downloading(let release, _), .installing(let release), .manual(let release, _), .ready(let release): return release
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
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang kiểm tra gói cập nhật…").foregroundStyle(.secondary) }
        case .ready(let release):
            ReadyToRestart(release: release)
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
        if let ready = updater.readyRelease {
            Button("Khởi động lại để cài \(ready.version)") { updater.restartNow() }
        } else {
            Button(updater.available.map { "Cài bản cập nhật \($0.version)…" } ?? "Kiểm tra cập nhật…") {
                if updater.available == nil { updater.check() }
                openPage()
            }
        }
    }
}

/// Sidebar toolbar pill shown only while a newer release is known, being installed, or just failed to install.
struct UpdateToolbarButton: View {
    @ObservedObject private var updater = SoftwareUpdater.shared
    @EnvironmentObject private var store: AppStore
    @OpenSettingsCompat private var openSettings
    @State private var open = false
    /// Kept so an install error stays reachable from the toolbar instead of the button vanishing.
    @State private var lastRelease: UpdateRelease?

    var body: some View {
        if let release = shownRelease {
            Button { open.toggle() } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { icon; Text(title).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
                        .padding(.horizontal, 12)
                    icon.frame(width: 36)
                }
                .frame(height: 36).contentShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(failed ? Color.orange : Color.accentColor).nativeGlass(18)
            .help(failed ? "Cài bản cập nhật \(release.version) chưa thành công" : "Có bản Zalolite \(release.version)")
            .popover(isPresented: $open, arrowEdge: .bottom) { panel(release) }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .onAppear { lastRelease = release }
            .onValueChange(of: release) { _, value in lastRelease = value }
        }
    }

    private var failed: Bool { if case .failed = updater.phase { return true }; return false }

    private var shownRelease: UpdateRelease? {
        switch updater.phase {
        case .available(let release), .downloading(let release, _), .installing(let release), .manual(let release, _), .ready(let release): return release
        case .failed: return lastRelease
        default: return nil
        }
    }

    private var title: String {
        switch updater.phase {
        case .downloading(_, let fraction): return "\(Int(fraction * 100))%"
        case .installing: return "Đang kiểm tra…"
        case .ready: return "Khởi động lại"
        case .failed: return "Lỗi cập nhật"
        default: return "Cập nhật"
        }
    }

    @ViewBuilder private var icon: some View {
        switch updater.phase {
        case .downloading(_, let fraction):
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15, weight: .medium))
        case .ready:
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 16, weight: .medium))
        default:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 16, weight: .medium))
        }
    }

    private func panel(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zalolite \(release.version)").font(.system(size: 15, weight: .semibold))
                    Text(subtitle(release)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(notes(release.notes)).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 200)
            }
            Divider()
            actions(release)
        }
        .padding(16).frame(width: 340)
    }

    private func subtitle(_ release: UpdateRelease) -> String {
        var text = "Bạn đang dùng \(updater.currentVersion)"
        if release.archiveSize > 0 { text += ", gói tải \(ByteCountFormatter.string(fromByteCount: Int64(release.archiveSize), countStyle: .file))" }
        return text
    }

    @ViewBuilder private func actions(_ release: UpdateRelease) -> some View {
        switch updater.phase {
        case .downloading(_, let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Button("Hủy") { updater.cancel() }
            }
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang kiểm tra gói cập nhật…").font(.callout).foregroundStyle(.secondary) }
        case .ready(let release):
            ReadyToRestart(release: release) { open = false }
        case .manual(_, let app):
            VStack(alignment: .leading, spacing: 8) {
                Text("Đã tải và kiểm tra xong. Thoát Zalolite rồi kéo bản mới trong Finder vào thư mục Applications.").font(.callout).foregroundStyle(.secondary)
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                HStack { details; Spacer(); Button("Thử lại") { updater.install(release) }.buttonStyle(.borderedProminent) }
            }
        default:
            HStack {
                details
                Spacer()
                Button("Để sau") { open = false }
                Button("Tải và cài đặt") { updater.install(release) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var details: some View {
        Button("Chi tiết…") {
            open = false; store.requestedSettingsPage = "updates"; NSApp.activate(ignoringOtherApps: true); openSettings()
        }
        .buttonStyle(.link)
    }

    private func notes(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// "Khởi động lại" now, or "Để sau": the verified update is then installed when Zalolite quits.
struct ReadyToRestart: View {
    @ObservedObject private var updater = SoftwareUpdater.shared
    let release: UpdateRelease
    var dismiss: () -> Void = {}
    @State private var later = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Đã tải và kiểm tra xong Zalolite \(release.version).", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Text(later ? "Bản mới sẽ được cài khi bạn thoát Zalolite. Bạn vẫn có thể khởi động lại bất cứ lúc nào."
                       : "Khởi động lại để dùng bản mới. Tin nhắn và cài đặt được giữ nguyên.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if !later { Button("Để sau") { later = true; dismiss() } }
                Button("Khởi động lại") { updater.restartNow() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}
