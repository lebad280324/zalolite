import SwiftUI
import AppKit
import LocalAuthentication

/// Picture behind the lock screen: none, the chat wallpaper, or a picture of the user's own.
enum LockBackground {
    static let choiceKey = "nativeLockBackground"
    static let imageKey = "nativeLockBackgroundImage"
    static let dimKey = "nativeLockBackgroundDim"
}

/// Shown over the whole window while Zalolite is locked.
struct LockedWorkspace: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(LockBackground.choiceKey) private var choice = "none"
    @AppStorage(LockBackground.imageKey) private var imagePath = ""
    @AppStorage(LockBackground.dimKey) private var dim = 0.0
    @State private var image: NSImage?
    @State private var failed = false
    @State private var asking = false
    @State private var prompted = false

    private var pictured: Bool { choice == "chat" || (choice == "image" && image != nil) }
    private var biometric: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text("Zalolite đã khóa").font(.title2.bold())
                Text("Mở khóa để xem tin nhắn. Thông báo vẫn đến, nhưng không hiện nội dung.")
                    .multilineTextAlignment(.center).opacity(0.8).frame(maxWidth: 360)
                if failed {
                    Text("Chưa mở khóa được. Hãy thử lại.").font(.callout.weight(.medium)).foregroundStyle(.orange)
                }
                Button { unlock() } label: {
                    Label(biometric ? "Mở khóa bằng Touch ID" : "Mở khóa", systemImage: biometric ? "touchid" : "lock.open")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(asking).padding(.top, 6)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 36).padding(.vertical, 30)
            // Over a picture the text sits on frosted glass, so the photo keeps its colours.
            .background {
                if pictured {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .zIndex(100)
        .task(id: imagePath + choice) {
            guard choice == "image", !imagePath.isEmpty else { image = nil; return }
            let path = imagePath
            image = await Task.detached { NSImage(contentsOfFile: path) }.value
        }
        .onAppear {
            // Ask once on its own, like other Mac apps with a lock; later attempts come from the button.
            guard !prompted, NSApp.isActive else { return }
            prompted = true; unlock()
        }
    }

    @ViewBuilder private var background: some View {
        switch choice {
        case "image" where image != nil:
            GeometryReader { proxy in
                Image(nsImage: image!).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
            if dim > 0 { Color.black.opacity(dim) }
        case "chat":
            ChatBackgroundView(thread: nil)
            if dim > 0 { Color.black.opacity(dim) }
        default:
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private func unlock() {
        guard !asking else { return }
        asking = true; failed = false
        NativeSystem.unlock { success in
            asking = false
            if success { store.isLocked = false } else { failed = true }
        }
    }
}

/// Settings → Tài khoản & khóa → Màn hình khóa.
struct LockBackgroundPicker: View {
    @AppStorage(LockBackground.choiceKey) private var choice = "none"
    @AppStorage(LockBackground.imageKey) private var imagePath = ""
    @AppStorage(LockBackground.dimKey) private var dim = 0.0
    @State private var preview: NSImage?
    @State private var failure: String?

    var body: some View {
        Picker("Hình nền màn hình khóa", selection: $choice) {
            Text("Mặc định").tag("none")
            Text("Theo hình nền trò chuyện").tag("chat")
            Text("Ảnh của bạn").tag("image")
        }
        .task(id: imagePath) {
            guard !imagePath.isEmpty else { preview = nil; return }
            let path = imagePath
            preview = await Task.detached { NSImage(contentsOfFile: path) }.value
        }
        if choice == "image" {
            HStack(spacing: 12) {
                ZStack {
                    if let preview { Image(nsImage: preview).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                    Color.black.opacity(dim)
                    Image(systemName: "lock.fill").foregroundStyle(.white)
                }
                .frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                Button(imagePath.isEmpty ? "Chọn ảnh…" : "Đổi ảnh…") { chooseImage() }
                Spacer()
            }
        }
        if choice != "none" {
            HStack {
                Text("Làm tối ảnh")
                Slider(value: $dim, in: 0...0.6)
                Text(dim < 0.01 ? "Tắt" : "\(Int(dim * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
        }
        if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.title = "Chọn ảnh cho màn hình khóa"; panel.prompt = "Dùng ảnh này"
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let saved = try await Task.detached { try ChatBackground.importImage(from: url, folder: "lock-background") }.value
                    imagePath = saved.path; choice = "image"; failure = nil
                } catch { failure = "Không đọc được ảnh đã chọn. Hãy thử ảnh JPEG, PNG hoặc HEIC khác." }
            }
        }
    }
}
