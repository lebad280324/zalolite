import AppKit
import SwiftUI

/// AppKit owns text composition, selection and the Vietnamese input method.
struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var enabled: Bool
    var focusRequest: String? = nil
    var onSend: () -> Void
    /// Returns true when the clipboard held files or an image that became attachments.
    var onPasteAttachments: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 300)
        return NSSize(width: width, height: Self.height(for: text, width: width))
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let bounds = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: NSSize(width: max(20, width - 22), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: MessageTextSize.size(14))])
        return min(120, max(34, ceil(bounds.height) + 16))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let editor = ComposerTextView()
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.onPasteAttachments = onPasteAttachments
        editor.isRichText = false
        // ⌘Z / ⇧⌘Z undo and redo typing and pasted text.
        editor.allowsUndo = true
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.font = .systemFont(ofSize: MessageTextSize.size(14))
        editor.textColor = .labelColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Nội dung tin nhắn")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        editor.onSend = onSend
        editor.onPasteAttachments = onPasteAttachments
        editor.isEditable = enabled
        // Follows Cài đặt → Giao diện → Cỡ chữ while the composer stays open.
        let readingSize = MessageTextSize.size(14)
        if editor.font?.pointSize != readingSize { editor.font = .systemFont(ofSize: readingSize) }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            editor.requestTypingFocus(focusRequest != nil)
        }
        if editor.string != text && !editor.hasMarkedText() {
            // A draft replaced from outside (another conversation, or cleared after sending) must not be
            // undone back into the previous text.
            if let storage = editor.textStorage { editor.undoManager?.removeAllActions(withTarget: storage) }
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var focusRequest: String?
        init(_ parent: NativeComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteAttachments: (() -> Bool)?
    private var needsTypingFocus = false
    private var insertObserver: NSObjectProtocol?
    private var formatObserver: NSObjectProtocol?
    /// The composer of the open conversation, the target of ⌘V when nothing else takes text.
    private static weak var active: ComposerTextView?
    private static var pasteMonitor: Any?

    /// Clipboard managers such as Clipy paste by posting ⌘V. When no text field has focus the
    /// standard Paste item has no target and the key is dropped; send it to the composer instead.
    private static func installPasteRouting() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let captured = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                let flags = captured.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command), !flags.contains(.control),
                      captured.charactersIgnoringModifiers?.lowercased() == "v",
                      let composer = active, composer.isEditable, let window = composer.window,
                      captured.window === window, window.attachedSheet == nil else { return false }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
                window.makeFirstResponder(composer)
                if flags.contains(.option) || flags.contains(.shift) { composer.pasteAsPlainText(nil) } else { composer.paste(nil) }
                return true
            }
            return handled ? nil : event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.active = self; Self.installPasteRouting() }
        if needsTypingFocus { requestTypingFocus(true) }
        if let formatObserver { NotificationCenter.default.removeObserver(formatObserver) }; formatObserver=nil
        if let insertObserver { NotificationCenter.default.removeObserver(insertObserver) }
        insertObserver = nil
        guard window != nil else { return }
        formatObserver = NotificationCenter.default.addObserver(forName:.composerFormatSelection,object:nil,queue:.main){[weak self] note in
            guard let marker=note.object as? String else{return}
            MainActor.assumeIsolated {
                guard let self,self.isEditable,!self.hasMarkedText() else{return}
                let range=self.selectedRange(),original=(self.string as NSString).substring(with:range)
                let prefix=note.userInfo?["prefix"] as? Bool ?? false
                let content=original.isEmpty ? "nội dung":original
                let value=prefix ? content.components(separatedBy:"\n").map{marker+$0}.joined(separator:"\n") : marker+content+marker
                self.window?.makeFirstResponder(self);self.insertText(value,replacementRange:range)
                self.setSelectedRange(NSRange(location:range.location+marker.utf16.count,length:content.utf16.count))
            }
        }
        // Text from pickers lands at the caret, replacing any selection, like typing it.
        insertObserver = NotificationCenter.default.addObserver(forName: .composerInsertText, object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, self.isEditable else { return }
                let keepFocus = note.userInfo?["keepFocus"] as? Bool == true
                if !keepFocus { self.window?.makeFirstResponder(self) }
                // The system picker opens beside the caret with its own zoom animation, as in Messages.
                if note.userInfo?["palette"] as? Bool == true { NSApp.orderFrontCharacterPalette(self); return }
                self.insertText(text, replacementRange: self.selectedRange())
            }
        }
    }
    /// A plain-text view reports images as unreadable, which disables Paste (⌘V) for a screenshot
    /// on the clipboard, so `paste(_:)` never ran. Files and images are attachments here.
    private static let attachmentTypes = ["public.image", "public.file-url"]
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if isEditable, item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)),
           NSPasteboard.general.canReadItem(withDataConformingToTypes: Self.attachmentTypes) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        // Files and images become attachments; text keeps the standard paste path.
        if isEditable, onPasteAttachments?() == true { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender:Any?) {if isEditable,onPasteAttachments?()==true{return};super.pasteAsPlainText(sender)}
    /// Defer until reply menus have closed and the editor is attached; later redraws keep the user's focus.
    func requestTypingFocus(_ requested: Bool) {
        needsTypingFocus = requested
        guard requested else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsTypingFocus, self.isEditable, let window = self.window else { return }
            if window.makeFirstResponder(self) { self.needsTypingFocus = false }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            // IME confirmation must reach AppKit before Return is interpreted as send.
            if hasMarkedText() { super.keyDown(with: event); return }
            let returnSends = UserDefaults.standard.object(forKey: "nativeSendWithReturn") as? Bool ?? true
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) || !returnSends && !event.modifierFlags.contains(.command) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if isEditable { onSend?() }
            return
        }
        super.keyDown(with: event)
    }
}
