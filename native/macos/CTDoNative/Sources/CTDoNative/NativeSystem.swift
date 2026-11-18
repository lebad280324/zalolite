import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import LocalAuthentication
import NativeBridge

@MainActor
final class NativeSystem: ObservableObject {
 @Published var notificationStatus = "Chưa kiểm tra quyền thông báo"
 @Published var launchAtLogin = false
 @Published var error: String?
 func refresh() {
  launchAtLogin = SMAppService.mainApp.status == .enabled
  UNUserNotificationCenter.current().getNotificationSettings { settings in
   Task { @MainActor in
    switch settings.authorizationStatus {
    case .authorized, .provisional: self.notificationStatus = "Đã được macOS cho phép"
    case .denied: self.notificationStatus = "Đang bị chặn trong Cài đặt hệ thống"
    default: self.notificationStatus = "Chưa được cấp quyền"
    }
   }
  }
 }
 func requestNotifications() {
  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { allowed, _ in
   Task { @MainActor in UserDefaults.standard.set(allowed, forKey: "nativeNotificationsEnabled"); self.refresh() }
  }
 }
 func setLaunchAtLogin(_ value: Bool) {
  Task {
   let failure: String? = await Task.detached {
    do { if value { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }; return nil }
    catch { return "Không thay đổi được mục đăng nhập. Kiểm tra Cài đặt hệ thống > Cài đặt chung > Mục đăng nhập." }
   }.value
   error = failure; refresh()
  }
 }
 static func unlock(_ completion: @escaping @MainActor (Bool) -> Void) {
  let context = LAContext()
  var failure: NSError?
  guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else { completion(false); return }
  context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Mở khóa Zalolite để xem cuộc trò chuyện") { success, _ in
   Task { @MainActor in completion(success) }
  }
 }
 static func captureScreen(hideApp: Bool) {
  let panel = NSSavePanel(); panel.title = "Lưu ảnh chụp màn hình"; panel.nameFieldStringValue = "Anh-chup-man-hinh.png"
  panel.begin { response in
   guard response == .OK, let url = panel.url else { return }
   if hideApp { NSApp.hide(nil) }
   Task {
    let success = await Task.detached {
     let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
     process.arguments = ["-i", "-x", url.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
     do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }.value
    if hideApp { NSApp.unhide(nil) }
    if success { NSWorkspace.shared.activateFileViewerSelecting([url]) }
   }
  }
 }
 static func refreshReminders(_ store: AppStore) {
  guard UserDefaults.standard.object(forKey: "nativeNotificationsEnabled") as? Bool ?? true, !store.demo else { return }
  let account = store.session.uin
  let rows = Array(store.features.rows("reminders").filter { !$0.flag("completed") && $0.number("remind_at") > Date().timeIntervalSince1970 }.prefix(50))
  UNUserNotificationCenter.current().getNotificationSettings { settings in
   guard settings.authorizationStatus == .authorized else { return }
   for row in rows {
    let content = UNMutableNotificationContent(); content.title = "Nhắc hẹn Zalolite"; content.body = row.string("title")
    if UserDefaults.standard.object(forKey: "nativeNotificationSound") as? Bool ?? true { content.sound = .default }
    let request = UNNotificationRequest(identifier: "reminder-\(account)-\(row.id)", content: content,
     trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, row.number("remind_at") - Date().timeIntervalSince1970), repeats: false))
    UNUserNotificationCenter.current().add(request) { _ in }
   }
  }
 }
}

struct CallOverlayView: View {
 @EnvironmentObject var store: AppStore
 @State private var mic = true
 @State private var camera = true
 @State private var pulse = false
 @State private var connectedAt: Date?
 @State private var ringer: Timer?
 @Environment(\.accessibilityReduceMotion) private var reducedMotion
 private var state: String { store.features.call?["state"]?.string ?? "" }
 private var incoming: JSONValue? { store.features.incomingCall }
 private var active: Bool { !store.isLocked && (incoming != nil || !["", "ended", "idle", "free", "rejected", "failed"].contains(state)) }
 private var isVideo: Bool { (incoming ?? store.features.call)?["is_video"]?.bool == true }
 private var name: String { incoming?["caller_name"]?.string ?? store.features.call?["partner_name"]?.string ?? "Cuộc gọi" }
 private var avatarThread: ThreadSnapshot? {
  let id = incoming?["caller_id"]?.string ?? store.selectedThreadID
  return store.threads.first { $0.id == id } ?? store.threads.first { $0.name == name }
 }
 var body: some View {
  ZStack {
   if active {
    Group { if incoming != nil { incomingCard } else { ongoingCard } }
     .transition(.asymmetric(insertion: .scale(scale: 0.86, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -20)),
                             removal: .scale(scale: 0.92, anchor: .top).combined(with: .opacity)))
   }
  }
  .animation(reducedMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: active)
  .animation(reducedMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: incoming == nil)
  .onValueChange(of: incoming == nil) { _, ended in ended ? stopRinging() : startRinging() }
  .onValueChange(of: state) { _, value in connectedAt = value == "connected" ? (connectedAt ?? Date()) : nil }
  .onAppear { if incoming != nil { startRinging() } }
  .onDisappear { stopRinging() }
 }

 /// Incoming call: identity first, then large decline and answer controls.
 private var incomingCard: some View {
  VStack(spacing: 14) {
   ZStack {
    ForEach(0..<2) { ring in
     Circle().stroke(Color.green.opacity(0.35), lineWidth: 2).frame(width: 84, height: 84)
      .scaleEffect(pulse ? 1.5 + CGFloat(ring) * 0.2 : 1).opacity(pulse ? 0 : 0.8)
      .animation(reducedMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(ring) * 0.5), value: pulse)
    }
    avatar(78)
   }.frame(height: 100).onAppear { pulse = true }
   VStack(spacing: 4) {
    Text(verbatim: name).font(.system(size: 19, weight: .bold)).lineLimit(1)
    Label(isVideo ? "Cuộc gọi video đến" : "Cuộc gọi thoại đến", systemImage: isVideo ? "video.fill" : "phone.fill")
     .font(.callout).foregroundStyle(.secondary)
   }
   HStack(spacing: 34) {
    roundButton("phone.down.fill", "Từ chối", .red) { answer(false, cameraOff: true) }
    if isVideo { roundButton("video.slash.fill", "Không camera", .gray) { answer(true, cameraOff: true) } }
    roundButton(isVideo ? "video.fill" : "phone.fill", "Trả lời", .green) { answer(true, cameraOff: false) }
   }.padding(.top, 4)
  }
  .padding(.horizontal, 30).padding(.vertical, 22).frame(width: 330)
  .modifier(MenuSurface(radius: 30))
 }

 /// Ongoing call: compact bar with timer and media controls; video frames above when present.
 private var ongoingCard: some View {
  VStack(spacing: 12) {
   if let frame = store.features.remoteFrame {
    Image(nsImage: frame).resizable().scaledToFit().frame(width: 360, height: 220).clipShape(RoundedRectangle(cornerRadius: 16))
     .overlay(alignment: .bottomTrailing) {
      if let local = store.features.localFrame {
       Image(nsImage: local).resizable().scaledToFit().frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 10)).padding(8)
      }
     }
   }
   HStack(spacing: 12) {
    avatar(40)
    VStack(alignment: .leading, spacing: 2) {
     Text(verbatim: name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
     if let connectedAt {
      TimelineView(.periodic(from: connectedAt, by: 1)) { context in
       Text(Duration.seconds(context.date.timeIntervalSince(connectedAt)).formatted(.time(pattern: .minuteSecond)))
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
     } else {
      Text(["preparing": "Đang chuẩn bị…", "calling": "Đang gọi…", "ringing": "Đang đổ chuông…"][state] ?? "Đang kết nối…")
       .font(.caption).foregroundStyle(.secondary)
     }
    }
    Spacer(minLength: 8)
    smallButton(mic ? "mic.fill" : "mic.slash.fill", mic ? "Tắt micrô" : "Bật micrô", mic ? Color.primary.opacity(0.1) : .orange) { mic.toggle(); updateMedia() }
    if isVideo { smallButton(camera ? "video.fill" : "video.slash.fill", camera ? "Tắt camera" : "Bật camera", camera ? Color.primary.opacity(0.1) : .orange) { camera.toggle(); updateMedia() } }
    smallButton("phone.down.fill", "Kết thúc", .red) { store.send("end_call") }
   }
  }
  .padding(14).frame(width: 380)
  .modifier(MenuSurface(radius: 26))
 }

 @ViewBuilder private func avatar(_ size: CGFloat) -> some View {
  if let thread = avatarThread { ThreadAvatar(thread: thread, size: size) } else { AvatarView(name: name, size: size) }
 }
 private func roundButton(_ icon: String, _ title: String, _ tint: Color, run: @escaping () -> Void) -> some View {
  Button(action: run) {
   VStack(spacing: 6) {
    Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
     .frame(width: 58, height: 58).background(tint.gradient, in: Circle()).shadow(color: tint.opacity(0.35), radius: 8, y: 3)
    Text(title).font(.caption).foregroundStyle(.secondary)
   }.contentShape(Rectangle())
  }.buttonStyle(LivelyButtonStyle()).help(title)
 }
 private func smallButton(_ icon: String, _ title: String, _ tint: Color, run: @escaping () -> Void) -> some View {
  Button(action: run) {
   Image(systemName: icon).font(.system(size: 14, weight: .semibold))
    .foregroundStyle(tint == .red || tint == .orange ? Color.white : Color.primary)
    .frame(width: 36, height: 36).background(tint, in: Circle())
  }.buttonStyle(LivelyButtonStyle()).help(title)
 }
 private func answer(_ accept: Bool, cameraOff: Bool) {
  store.send("answer_call", parameters: ["accept": .bool(accept), "cam_start_off": .bool(cameraOff)])
  camera = !cameraOff
  store.features.incomingCall = nil
 }
 /// A soft system tone repeats while the call rings, unless notification sounds are off.
 private func startRinging() {
  guard ringer == nil, incoming != nil, UserDefaults.standard.object(forKey: "nativeNotificationSound") as? Bool ?? true else { return }
  NSSound(named: "Submarine")?.play()
  ringer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in NSSound(named: "Submarine")?.play() }
 }
 private func stopRinging() { ringer?.invalidate(); ringer = nil }
 func updateMedia() { store.send("set_call_media", parameters: ["is_on_mic": .bool(mic), "is_on_cam": .bool(camera)]) }
}
