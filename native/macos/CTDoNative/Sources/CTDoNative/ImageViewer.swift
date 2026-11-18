import AppKit
import SwiftUI
import NativeBridge

extension Notification.Name {
    /// Asks the workspace to show a photo in the in-window viewer.
    static let openImageViewer = Notification.Name("vn.ctdo.native.openImageViewer")
    /// Swaps the photo of an open viewer for a better copy (original profile photo); ignored when closed.
    static let replaceImageViewer = Notification.Name("vn.ctdo.native.replaceImageViewer")
}

/// In-window photo viewer: glass frame, pinch or scroll to zoom, drag to pan, double-click to toggle.
struct ImageViewerOverlay: View {
    let url: URL
    let close: () -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var image: NSImage?
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var monitor: Any?
    @State private var appeared = false
    private let range: ClosedRange<CGFloat> = 1...8

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.18).ignoresSafeArea())
                .onTapGesture { dismiss() }
            GeometryReader { proxy in
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(magnify.simultaneously(with: pan))
                            .onTapGesture(count: 2) { toggleZoom() }
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(14)
            .background { RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black.opacity(0.22)) }
            .nativeGlass(30)
            .overlay { RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.horizontal, 60).padding(.top, 54).padding(.bottom, 92)
            .scaleEffect(appeared ? 1 : 0.92).opacity(appeared ? 1 : 0)
            VStack {
                Spacer()
                controls.padding(.bottom, 26)
            }
        }
        .onAppear {
            withAnimation(reducedMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) { appeared = true }
            installScrollZoom()
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .task(id: url) { image = await AnimatedImageCache.image(for: url) }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            control("minus.magnifyingglass", "Thu nhỏ") { zoom(to: scale / 1.4) }
            Text("\(Int((scale * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 48)
            control("plus.magnifyingglass", "Phóng to") { zoom(to: scale * 1.4) }
            control("arrow.down.right.and.arrow.up.left", "Vừa khung") { zoom(to: 1) }
            Divider().frame(height: 18).padding(.horizontal, 4)
            control("square.and.arrow.down", "Lưu về máy") { saveImage() }
            control("doc.on.doc", "Sao chép ảnh") { if let image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } }
            control("safari", "Mở bằng trình duyệt") { NSWorkspace.shared.open(url) }
            Divider().frame(height: 18).padding(.horizontal, 4)
            control("xmark", "Đóng (Esc)") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .modifier(MenuSurface(radius: 22))
    }

    private func control(_ icon: String, _ help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32).contentShape(Circle()) }
            .buttonStyle(LivelyButtonStyle()).help(help)
    }

    private var magnify: some Gesture {
        #if LEGACY_MACOS13
        MagnificationGesture()
            .onChanged { value in scale = min(range.upperBound, max(range.lowerBound * 0.8, pinchBase * value)) }
            .onEnded { _ in zoom(to: scale); pinchBase = scale }
        #else
        MagnifyGesture()
            .onChanged { value in scale = min(range.upperBound, max(range.lowerBound * 0.8, pinchBase * value.magnification)) }
            .onEnded { _ in zoom(to: scale); pinchBase = scale }
        #endif
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: dragBase.width + value.translation.width, height: dragBase.height + value.translation.height)
            }
            .onEnded { _ in dragBase = offset }
    }

    private func zoom(to value: CGFloat) {
        let target = min(range.upperBound, max(range.lowerBound, value))
        withAnimation(reducedMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            scale = target
            if target <= 1 { offset = .zero; dragBase = .zero }
        }
        pinchBase = target
    }

    private func toggleZoom() { zoom(to: scale > 1.05 ? 1 : 2.5) }

    /// Mouse wheels zoom too, so the viewer works without a trackpad.
    private func installScrollZoom() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            nonisolated(unsafe) let captured = event
            MainActor.assumeIsolated {
                let delta = captured.hasPreciseScrollingDeltas ? captured.scrollingDeltaY / 120 : captured.scrollingDeltaY / 12
                let next = min(range.upperBound, max(range.lowerBound, scale * (1 + delta)))
                scale = next; pinchBase = next
                if next <= 1 { offset = .zero; dragBase = .zero }
            }
            return nil
        }
    }

    private func saveImage() {
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Anh-Zalolite.png"; panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            Task.detached { try? png.write(to: target, options: .atomic) }
        }
    }

    private func dismiss() {
        withAnimation(reducedMotion ? nil : .easeIn(duration: 0.16)) { appeared = false }
        Task { @MainActor in try? await Task.sleep(nanoseconds: 170_000_000); close() }
    }
}
