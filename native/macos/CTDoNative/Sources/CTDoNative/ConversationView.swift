import SwiftUI
import AppKit
import NativeBridge

struct ConversationView: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSnapshot
    /// The composer text; observed here so typing redraws this view, not the whole window.
    @ObservedObject var composerDraft: ComposerDraft
    /// Replaces the centred title, e.g. the chat bubble's own header with its window buttons.
    var customHeader: AnyView? = nil
    @State private var confirmRecall: MessageSnapshot?
    @State private var showingSchedule = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var mediaOnly = false
    @AppStorage("nativeShowThumbnails") private var showThumbnails = true
    @State private var confirmBulkDelete = false
    @State private var dropTargeted = false
    @State private var showingEmoji = false
    @State private var showingComposerMenu = false
    @State private var showingContactCard = false
    @State private var showingFormatting = false
    @StateObject private var swipe = SwipeReplyTracker()
    @State private var showingStickers = false
    @State private var menuTarget: MessageMenuTarget?
    /// Read only when a menu opens; a plain box keeps window resizes from re-evaluating this view every frame.
    @State private var columnFrame = FrameBox()
    @StateObject private var menuMonitor = MessageMenuMonitor()
    /// The window this conversation is drawn in; event monitors act only on events from it.
    @State private var hostWindow = WindowBox()
    /// Position in `store.conversationSearchHits` (0 = newest match).
    @State private var searchIndex = 0
    private var hasDraft: Bool {
        !store.pendingAttachments.isEmpty || !composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            // Beside the transcript when there is room; otherwise the card floats over it.
            let sideBySide = proxy.size.width >= 380 + 356
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    mainColumn
                    if store.showingInspector && sideBySide { Color.clear.frame(width: 356) }
                }
                // Clicking anywhere outside the details card closes it, like Esc or its close button.
                if store.showingInspector {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { store.showingInspector = false }
                }
                if store.showingInspector {
                    ConversationInfoPanel(thread: thread).id(thread.id)
                        .frame(width: 340)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: max(12, store.windowCornerRadius - 8), style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: max(12, store.windowCornerRadius - 8), style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: max(12, store.windowCornerRadius - 8), style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(sideBySide ? 0 : 0.18), radius: 20, y: 6)
                        .padding(.trailing, 8).padding(.top, 8).padding(.bottom, 8)
                        // Reaches up into the toolbar band, close to the window's top edge.
                        .ignoresSafeArea(.container, edges: .top)
                        .transition(.asymmetric(insertion: .scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity),
                                                removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)))
                }
            }
        }
        .animation(reducedMotion ? nil : .snappy(duration: 0.25), value: store.showingInspector)
    }

    private var mainColumn: some View {
        return ConversationViewport { top, bottom in
            transcript(topInset: top, bottomInset: bottom)
        } header: {
            VStack(spacing: 0) {
                if let customHeader {
                    customHeader
                } else {
                    GeometryReader { proxy in
                        ConversationHeader(thread: thread, availableWidth: max(160, proxy.size.width - 28))
                            .frame(maxWidth: .infinity, maxHeight: .infinity).id(thread.id)
                    }.frame(height: 76)
                }
                conversationControls
                StrangerBanner(thread: thread)
                PinnedMessagesBar(thread: thread)
            }
        } composer: {
            composer
        }
        .ignoresSafeArea(.container, edges: .top)
        .onValueChange(of:store.jumpMessageID){_,target in
            guard let target else{return};mediaOnly=false;store.highlightedMessageID=target
            Task{@MainActor in
                try? await Task.sleep(nanoseconds:2_200_000_000)
                if store.highlightedMessageID==target{store.highlightedMessageID=nil}
            }
        }
        .onValueChange(of:store.conversationSearch){_,query in store.transcript.configure(query:query,media:mediaOnly,threadID:thread.id)}
        .onValueChange(of:mediaOnly){_,value in store.transcript.configure(query:store.conversationSearch,media:value,threadID:thread.id)}
        .toolbarBackground(.hidden, for:.windowToolbar)
        .onAppear {
            swipe.install(hovered: { [hostWindow] in store.selectingMessages == false && hostWindow.owns(NSApp.currentEvent) ? TranscriptPointer.messageID() : nil },
                          onReply: { id in if let message = store.selectedMessages.first(where: { $0.id == id }), store.supports("send_quote") { store.quote = message } })
        }
        .onAppear {
            menuMonitor.install(hovered: { [hostWindow] in store.selectingMessages || !hostWindow.owns(NSApp.currentEvent) ? nil : TranscriptPointer.messageID() }) { [hostWindow] id, location in
                guard let message = store.selectedMessages.first(where: { $0.id == id }) else { return }
                // AppKit reports window points from the bottom; SwiftUI frames are measured from the top.
                let height = (hostWindow.window ?? NSApp.keyWindow)?.contentView?.bounds.height ?? 0
                let point = CGPoint(x: location.x - columnFrame.value.minX, y: height - location.y - columnFrame.value.minY)
                menuTarget = MessageMenuTarget(message: message, point: point)
            }
            if thread.isGroup, store.features.members[thread.id] == nil, store.supports("get_group_members") {
                store.threadCommand("get_group_members", thread: thread)
            }
            if !thread.isGroup { store.requestProfile(thread.id) }
        }
        .onValueChange(of: thread.id) { _, _ in
            // The view is reused across threads; anything transient belongs to the thread that was left.
            mediaOnly = false; menuTarget = nil; confirmRecall = nil; confirmBulkDelete = false; dropTargeted = false
            showingSchedule = false; showingEmoji = false; showingComposerMenu = false; showingContactCard = false
            showingFormatting = false; showingStickers = false
            if !thread.isGroup { store.requestProfile(thread.id) }
            if thread.isGroup, store.features.members[thread.id] == nil, store.supports("get_group_members") {
                store.threadCommand("get_group_members", thread: thread)
            }
        }
        .onDisappear { swipe.remove(); menuMonitor.remove() }
        .background(WindowReader(box: hostWindow))
        .background { GeometryReader { proxy in Color.clear.onAppear { columnFrame.value = proxy.frame(in: .global) }
            .onValueChange(of: proxy.frame(in: .global)) { _, frame in columnFrame.value = frame } } }
        .overlay(alignment: .topLeading) {
            if let target = menuTarget {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { menuTarget = nil }
                        Button("") { menuTarget = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                        MessageActionMenu(message: target.message, thread: thread, close: { menuTarget = nil }, recall: { confirmRecall = target.message })
                            .fixedSize()
                            .offset(x: max(8, min(target.point.x - 20, proxy.size.width - 500)),
                                    y: max(8, min(target.point.y - 56, proxy.size.height - 500)))
                            .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(reducedMotion ? nil : .snappy(duration: 0.16), value: menuTarget?.message.id)
        .onReceive(NotificationCenter.default.publisher(for: .snapshotOpenMenu)) { _ in
            if store.demo, let message = store.selectedMessages.first { menuTarget = MessageMenuTarget(message: message, point: CGPoint(x: 120, y: 150)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snapshotOpenEmoji)) { _ in if store.demo { showingEmoji = true } }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptLatest)) { note in
            guard note.object as? String == thread.id else {return}
            store.showLatest(thread)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard store.supports("send_attachment"), !files.isEmpty else { return false }
            store.addAttachments(files); return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    .overlay { Label("Thả tệp để thêm vào tin nhắn", systemImage: "arrow.down.doc").font(.title3) }
                    .padding(24).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingContactCard) { ContactCardPicker(thread: thread) }
        .popover(isPresented: $showingFormatting) { FormattingPanel() }
        .confirmationDialog("Xóa tin nhắn này cho cả nhóm?", isPresented: Binding(get: { store.deleteForEveryoneCandidate != nil }, set: { if !$0 { store.deleteForEveryoneCandidate = nil } }), titleVisibility: .visible) {
            Button("Xóa cho cả nhóm", role: .destructive) {
                if let message = store.deleteForEveryoneCandidate { store.deleteForEveryone(message) }
                store.deleteForEveryoneCandidate = nil
            }
            Button("Hủy", role: .cancel) { store.deleteForEveryoneCandidate = nil }
        } message: { Text("Tin nhắn sẽ bị xóa với mọi thành viên. Chỉ trưởng hoặc phó nhóm làm được, trong thời gian Zalo cho phép.") }
        .confirmationDialog("Thu hồi tin nhắn này?", isPresented: Binding(get: { confirmRecall != nil }, set: { if !$0 { confirmRecall = nil } }), titleVisibility: .visible) {
            Button("Thu hồi", role: .destructive) {
                if let message = confirmRecall { store.messageAction("recall_message", message: message) }
                confirmRecall = nil
            }
            Button("Hủy", role: .cancel) { confirmRecall = nil }
        } message: { Text("Tin nhắn sẽ được thu hồi trong cuộc trò chuyện của mọi người.") }
    }

    private var conversationControls:some View {
            VStack(spacing: 6) {
                if store.showingConversationSearch { searchBar }
                if mediaOnly {
                    HStack {
                        Label("Đang xem ảnh và tệp đã tải", systemImage: "photo.on.rectangle").font(.caption)
                        Spacer()
                        Button("Xem tất cả tin nhắn") { mediaOnly = false }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                    }.padding(.horizontal, 12).padding(.vertical, 7).nativeGlass(12).padding(.horizontal, 14)
                }
                if store.selectingMessages { selectionBar }
            }.padding(.top, store.showingConversationSearch || mediaOnly || store.selectingMessages ? 6 : 0)
    }

    private func transcript(topInset: CGFloat, bottomInset: CGFloat) -> AnyView {
        AnyView(TranscriptPane(model:store.transcript,threadID:thread.id,hovered:nil,selection:store.selectedMessageIDs,selecting:store.selectingMessages,highlighted:store.highlightedMessageID,showThumbnails:showThumbnails,swipeID:swipe.messageID,swipeOffset:swipe.offset,jump:store.jumpMessageID,loading:store.pageRequests[thread.id] != nil,rowContent:{AnyView(transcriptRow($0,hovered:$1).environmentObject(store).environment(\.colorScheme,colorScheme))},nativeRow:nativeRow,nativeActions:nativeActions,topInset:topInset,bottomInset:bottomInset,loadMore:{store.loadMessages(thread,more:true)},loadNewer:{store.loadMessages(thread,newer:true)}).equatable())
    }
    /// Text, quotes, photos and links draw with CoreText; stickers and file cards stay SwiftUI rows.
    private var nativeRow:(TranscriptRow)->NativeRowInput? {
        let thread=thread,store=store,showThumbnails=showThumbnails,swipeID=swipe.messageID,swipeOffset=swipe.offset
        // Resolving a group member scans the member list; do it once per sender, not once per row per frame.
        let identities=IdentityCache()
        return {row in
            guard row.album.isEmpty, NativeRowSupport.supports(row.message) else{return nil}
            let key=row.message.senderID+"\u{1}"+row.message.senderName
            let identity=identities.values[key] ?? store.senderIdentity(row.message,in:thread)
            identities.values[key]=identity
            return NativeRowInput(row:row,isGroup:thread.isGroup,selecting:store.selectingMessages,
                selected:store.selectedMessageIDs.contains(row.id),highlighted:store.highlightedMessageID==row.id,
                showThumbnails:showThumbnails,senderName:identity.name,senderAvatar:identity.avatar,senderID:identity.id,
                swipeOffset:swipeID==row.id ? swipeOffset : 0,
                searchTerm:store.conversationSearch.trimmingCharacters(in:.whitespacesAndNewlines))
        }
    }
    private var nativeActions:NativeRowActions {
        let thread=thread,store=store
        return NativeRowActions(
            toggleSelection:{id in if store.selectedMessageIDs.contains(id){store.selectedMessageIDs.remove(id)}else{store.selectedMessageIDs.insert(id)}},
            reply:{message in if UserDefaults.standard.bool(forKey:"nativeDoubleClickReply"),store.supports("send_quote"){store.quote=message}},
            quoteJump:{store.jump(toThread:thread.id,messageID:$0)},
            profile:{input,view,rect in
                // Open above or below the avatar, whichever has more screen room, so the card stays on screen.
                let inWindow=view.convert(rect,to:nil)
                var above=(view.window?.contentView?.bounds.height ?? 800)-inWindow.maxY-PopoverRoom.margin*2,below=inWindow.minY-PopoverRoom.margin*2
                if let window=view.window,let screen=window.screen {
                    let onScreen=window.convertToScreen(inWindow),visible=screen.visibleFrame
                    above=visible.maxY-onScreen.maxY-PopoverRoom.margin*2;below=onScreen.minY-visible.minY-PopoverRoom.margin*2
                }
                let up=above>below,room=max(200,up ? above : below)
                let edge:NSRectEdge=view.isFlipped ? (up ? .minY : .maxY) : (up ? .maxY : .minY)
                let popover=NSPopover();popover.behavior = .transient
                popover.contentViewController=NSHostingController(rootView:ContactProfilePopover(userID:input.senderID,name:input.displayName,avatar:input.senderAvatar){[weak popover] in popover?.close()}.environment(\.popoverMaxHeight,room).environmentObject(store))
                popover.show(relativeTo:rect,of:view,preferredEdge:edge)
            })
    }
    @ViewBuilder private func transcriptRow(_ row:TranscriptRow,hovered:Bool)->some View {
                        let message = row.message
                        let opensRun = row.startsRun
                        if row.showsTimestamp {
                            // A floating date pill, readable on any wallpaper; times now live inside bubbles.
                            Group {
                                if Calendar.current.isDateInToday(message.date) { Text("Hôm nay") }
                                else if Calendar.current.isDateInYesterday(message.date) { Text("Hôm qua") }
                                else { Text(message.date, format: .dateTime.weekday(.wide).day().month(.wide)) }
                            }
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.75))
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 12).padding(.bottom, 8).frame(maxWidth: .infinity)
                        }
                        if message.messageType == "chat.system", let poll = message.pollID {
                            PollCard(message: message, thread: thread, pollID: poll).id(message.id)
                        } else if message.messageType == "chat.system" {
                            GroupNoticePill(message: message, thread: thread).id(message.id)
                                .contextMenu {
                                    Button("Sao chép", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                                    Button("Xem chi tiết", systemImage: "info.circle") { store.messageDetails = message }
                                }
                        } else {
                        HStack(alignment: .bottom) {
                            if store.selectingMessages {
                                Toggle("Chọn tin", isOn: Binding(get: { store.selectedMessageIDs.contains(message.id) },
                                                                set: { if $0 { store.selectedMessageIDs.insert(message.id) } else { store.selectedMessageIDs.remove(message.id) } }))
                                    .labelsHidden().toggleStyle(.checkbox).frame(width: 24)
                            }
                            let identity = store.senderIdentity(message, in: thread)
                            MessageRow(message: message, showSender: thread.isGroup && !message.isOutgoing && opensRun,
                                       showAvatar: !message.isOutgoing && row.endsRun,
                                       reserveAvatar: !message.isOutgoing,
                                       highlighted: store.highlightedMessageID == message.id, showThumbnails: showThumbnails,
                                       senderName: identity.name, senderAvatar: identity.avatar, senderID: identity.id,
                                       firstInRun: opensRun, lastInRun: row.endsRun, isGroup: thread.isGroup, album: row.album,
                                       onQuoteJump: { store.jump(toThread: thread.id, messageID: $0) },
                                       resolveMention: { [weak store] in store?.mentionedMember($0) }).equatable()
                        }
                        .offset(x: swipe.messageID == message.id ? swipe.offset : 0)
                        .background(alignment: swipe.offset >= 0 ? .leading : .trailing) {
                            if swipe.messageID == message.id && abs(swipe.offset) > 8 {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(abs(swipe.offset) >= SwipeReplyTracker.threshold ? Color.accentColor : Color.secondary)
                                    .opacity(min(1, abs(swipe.offset) / SwipeReplyTracker.threshold))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.top, opensRun ? 6 : 0)
                        .onTapGesture(count: 2) { if UserDefaults.standard.bool(forKey: "nativeDoubleClickReply") { store.quote = message } }
                        .id(message.id)
                        .contextMenu { messageMenu(message) }
                        }

    }

    private func toggleSearch() {
        store.showingConversationSearch.toggle()
        if !store.showingConversationSearch { store.conversationSearch = "" }
    }

    private var searchBar: some View {
        let hits = store.conversationSearchHits
        let query = store.conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tìm trong cuộc trò chuyện này", text: $store.conversationSearch).textFieldStyle(.plain)
                .onSubmit { stepSearch(older: !NSEvent.modifierFlags.contains(.shift)) }
            if !query.isEmpty {
                Text(hits.isEmpty ? "Không có kết quả" : "\(min(searchIndex, hits.count - 1) + 1)/\(hits.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                Button { stepSearch(older: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(searchIndex >= hits.count - 1).help("Kết quả cũ hơn (Enter)")
                Button { stepSearch(older: false) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(searchIndex <= 0).help("Kết quả mới hơn (Shift-Enter)")
            }
            if store.supports("search_history") {
                Button("Toàn bộ lịch sử…") { store.showingHistorySearch = true }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                    .help("Tìm trong lịch sử đã lưu trên máy")
            }
            Button { store.conversationSearch = ""; store.showingConversationSearch = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Đóng tìm kiếm")
        }.padding(.horizontal, 12).padding(.vertical, 8).nativeGlass(18).padding(.horizontal, 14)
        .task(id: query) {
            // Typing settles first, then the newest match is shown, as in Zalo.
            searchIndex = 0
            guard !query.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            showSearchHit(0)
        }
    }

    private func stepSearch(older: Bool) {
        let count = store.conversationSearchHits.count
        guard count > 0 else { return }
        searchIndex = max(0, min(count - 1, searchIndex + (older ? 1 : -1)))
        showSearchHit(searchIndex)
    }

    private func showSearchHit(_ index: Int) {
        let hits = store.conversationSearchHits
        guard hits.indices.contains(index) else { return }
        let id = hits[index].id
        Task { @MainActor in
            store.jumpMessageID = nil
            await Task.yield()
            store.jumpMessageID = id
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("Đã chọn \(store.selectedMessageIDs.count)").font(.callout.weight(.medium))
            Button("Sao chép", systemImage: "doc.on.doc") {
                let text = store.chosenMessages.map(\.text).joined(separator: "\n")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            if store.supports("forward_message") { Button("Chuyển tiếp…", systemImage: "arrowshape.turn.up.right") { store.forwardChosen() } }
            if store.supports("bookmark_message") { Button("Đánh dấu", systemImage: "star") { store.bookmarkChosen() } }
            if store.supports("delete_message") { Button("Xóa ở phía tôi…", systemImage: "trash", role: .destructive) { confirmBulkDelete = true } }
            Spacer()
            Button("Xong") { store.finishSelecting() }.keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 12).padding(.vertical, 8).nativeGlass(14).padding(.horizontal, 14)
            .confirmationDialog("Xóa \(store.selectedMessageIDs.count) tin nhắn ở phía bạn?", isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Xóa ở phía tôi", role: .destructive) { store.deleteChosen() }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Tin nhắn chỉ bị xóa trên tài khoản này; người khác vẫn thấy. Thao tác không hoàn tác được.") }
    }

    private var composer: some View {
        VStack(spacing:8) {
            ComposerAssist(thread:thread, composer:store.composer).id(thread.id)
            TypingBar(tracker: store.typing, thread: thread)
            if store.strangerBlocked.contains(thread.id) && !thread.isGroup && !store.sendBlocked.contains(thread.id) {
                HStack(spacing:9) {
                    Image(systemName:"person.crop.circle.badge.exclamationmark").font(.system(size:16,weight:.semibold)).foregroundStyle(.orange)
                    VStack(alignment:.leading,spacing:1) {
                        Text("\(thread.name) không nhận tin nhắn từ người lạ").font(.system(size:13,weight:.semibold)).lineLimit(1)
                        Text("Bạn chưa thể gửi tin nhắn đến người này. Gửi lời mời kết bạn để trò chuyện.")
                            .font(.system(size:11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength:6)
                    if store.supports("add_friend") {
                        Button("Gửi kết bạn") { store.send("add_friend", parameters: ["user_id": .string(thread.id)]) }
                            .buttonStyle(.borderedProminent).controlSize(.small).capsuleButtonShape()
                            .disabled(store.busy.contains("add_friend"))
                    }
                }
                .padding(.horizontal,12).padding(.vertical,9)
                .nativeGlass(14)
                .background(Color.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:14,style:.continuous))
                .transition(.move(edge:.bottom).combined(with:.opacity))
            }
            if store.sendBlocked.contains(thread.id) || (!thread.isGroup && store.hasBlocked(thread.id)) {
                let mine = !thread.isGroup && store.hasBlocked(thread.id)
                HStack(spacing:9) {
                    Image(systemName:"nosign").font(.system(size:15,weight:.semibold)).foregroundStyle(.red)
                    VStack(alignment:.leading,spacing:1) {
                        Text(mine ? "Bạn đã chặn người này" : thread.isGroup ? "Không thể gửi tin nhắn" : "\(thread.name) đã chặn bạn").font(.system(size:13,weight:.semibold))
                        Text(mine ? "Bỏ chặn để nhắn tin và gọi cho nhau." : thread.isGroup ? "Zalo từ chối tin nhắn trong nhóm này: bạn có thể đã bị chặn hoặc nhóm đang khoá gửi tin." : "Hoặc người này không nhận tin nhắn từ người lạ. Zalo từ chối tin nhắn và cuộc gọi tới họ.")
                            .font(.system(size:11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength:6)
                    if mine && store.supports("set_contact_blocked") {
                        Button("Bỏ chặn") { store.send("set_contact_blocked", parameters: ["user_id": .string(thread.id), "blocked": .bool(false)]) }
                            .buttonStyle(.bordered).controlSize(.small).capsuleButtonShape()
                    }
                }
                .padding(.horizontal,12).padding(.vertical,9)
                .nativeGlass(14)
                .background(Color.red.opacity(0.06),in:RoundedRectangle(cornerRadius:14,style:.continuous))
                .transition(.move(edge:.bottom).combined(with:.opacity))
            }
            HStack(alignment:.bottom,spacing:8) {
                composerMenu.padding(.bottom,0)
                if store.supports("send_sticker") && store.supports("sticker_packs") {
                    Button { showingStickers.toggle() } label: {
                        // A smiling page, distinct from the emoji face inside the field.
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(lineWidth: 1.6).frame(width: 22, height: 22)
                            Image(systemName: "face.smiling").font(.system(size: 13, weight: .medium))
                        }.frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(LivelyButtonStyle()).nativeGlass(22).help("Nhãn dán").accessibilityLabel("Nhãn dán")
                    .disabled(!store.canSend)
                    .popover(isPresented: $showingStickers, arrowEdge: .top) { StickerPopover { showingStickers = false } }
                }
                VStack(spacing:10) {
                    if let quote=store.quote {
                        HStack(spacing:9) {
                            RoundedRectangle(cornerRadius:2).fill(.tint).frame(width:3)
                            VStack(alignment:.leading,spacing:3) {
                                Text("Trả lời \(quote.senderName.isEmpty ? thread.name : quote.senderName)").font(.caption.weight(.semibold))
                                Text(verbatim:quote.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer();Button{withAnimation{store.quote=nil}}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help("Hủy trả lời")
                        }.frame(maxHeight:48).padding(8).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
                         .transition(.move(edge:.bottom).combined(with:.opacity))
                    }
                    if !store.pendingAttachments.isEmpty { DraftAttachments().transition(.move(edge:.bottom).combined(with:.opacity)) }
                    HStack(alignment:.center,spacing:6) {
                        ZStack(alignment:.topLeading) {
                            NativeComposer(text:$composerDraft.text,enabled:store.ready && store.session.loggedIn,focusRequest:store.quote.map { _ in thread.id + ":" + String(store.replyFocusGeneration) },onSend:{store.submitComposer()},onPasteAttachments:{store.pasteAttachments()})
                        }.frame(minHeight:34)
                        Button{showingEmoji.toggle()}label:{Image(systemName:"face.smiling").font(.system(size:19)).frame(width:30,height:34)}
                            .buttonStyle(LivelyButtonStyle()).help("Biểu tượng cảm xúc (⌃⌘Space)")
                            .popover(isPresented:$showingEmoji,arrowEdge:.top){EmojiPickerPopover()}
                        if store.isSending {ProgressView().controlSize(.small).padding(6)}
                        else if hasDraft {Button{store.submitComposer()}label:{Image(systemName:"arrow.up").font(.system(size:14,weight:.bold)).foregroundStyle(.white).frame(width:30,height:30).background(Color.accentColor,in:Circle())}.buttonStyle(LivelyButtonStyle()).disabled(!store.canSend).help("Gửi (Return)").transition(.scale.combined(with:.opacity))}
                    }
                }.padding(.horizontal,10).padding(.vertical,5).modifier(ReadableComposerSurface())

            }
        }.padding(.horizontal,14).padding(.top,8).padding(.bottom,12)
         .animation(reducedMotion ? nil : .snappy(duration:0.22),value:store.quote?.id)
         .animation(reducedMotion ? nil : .snappy(duration:0.22),value:store.pendingAttachments.count)
         .animation(reducedMotion ? nil : .easeOut(duration:0.14),value:hasDraft)
    }
    private var composerMenu: some View {
        Button { showingComposerMenu.toggle() } label: {
            Image(systemName: "plus").font(.system(size:20,weight:.light)).frame(width:44,height:44)
        }.buttonStyle(LivelyButtonStyle()).nativeGlass(22).help("Thêm nội dung")
         .popover(isPresented:$showingComposerMenu,arrowEdge:.top) {
             ComposerActionPanel(thread:thread, close:{showingComposerMenu=false},
                 card:{showingContactCard=true}, format:{showingFormatting=true}, schedule:{showingSchedule=true})
         }
         .popover(isPresented:$showingSchedule){ScheduleSendView()}
    }

    @ViewBuilder private func messageMenu(_ message: MessageSnapshot) -> some View {
        Button("Xem chi tiết",systemImage:"info.circle") {store.messageDetails=message}
        Button("Chọn nhiều tin nhắn",systemImage:"checkmark.circle") {store.selectingMessages=true;store.selectedMessageIDs.insert(message.id)}
        if store.supports("bookmark_message") { Button(store.isBookmarked(message,thread:thread) ? "Bỏ đánh dấu":"Đánh dấu",systemImage:"star") {store.setBookmark(message,thread:thread,marked: !store.isBookmarked(message,thread:thread))} }
        if store.supports("pin_message_local") {
            let pinned = store.features.rows("pinned_messages").contains { $0.string("thread_id") == thread.id && $0.string("message_id") == message.id }
            Button(pinned ? "Bỏ ghim trên máy" : "Ghim trên máy", systemImage: pinned ? "pin.slash" : "pin") {
                store.featureThread("pin_message_local", thread: thread, values: ["message_id": .string(message.id), "pinned": .bool(!pinned)])
            }
        }
        if message.imageURL != nil || message.fileURL != nil { Button("Lưu về máy…",systemImage:"arrow.down") {store.downloadMedia(message)} }
        if message.imageURL != nil { Button("Sao chép ảnh",systemImage:"photo") {store.copyPhoto(message)} }
        Divider()
        if store.supports("send_quote") {
            Button("Trả lời", systemImage: "arrowshape.turn.up.left") { store.quote = message }
        }
        Button("Sao chép", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(MessageTypography.inline(message.text).characters), forType: .string)
        }
        if store.supports("forward_message") {
            Button("Chuyển tiếp…", systemImage: "arrowshape.turn.up.right") { store.openForward(message) }
        }
        if store.supports("react") {
            Menu("Thả cảm xúc") {
                ForEach(["👍", "❤️", "😆", "😮", "😢", "😡"], id: \.self) { emoji in
                    Button(emoji) { store.messageAction("react", message: message, reaction: emoji) }
                }
            }
        }
        if let url = safeWebURL(message.fileURL) {
            Button("Mở tệp đính kèm", systemImage: "arrow.down.doc") { NSWorkspace.shared.open(url) }
        }
        if store.supports("recall_message") && message.isOutgoing {
            Divider()
            Button("Thu hồi…", systemImage: "arrow.uturn.backward", role: .destructive) { confirmRecall = message }
        }
        if store.supports("delete_message") {
            Button("Xóa ở phía tôi", systemImage: "trash", role: .destructive) { store.messageAction("delete_message", message: message) }
            if store.canDeleteForEveryone(message, in: thread) {
                Button("Xóa cho cả nhóm…", systemImage: "trash.slash", role: .destructive) { store.deleteForEveryoneCandidate = message }
            }
        }
    }


}


final class FrameBox { var value: CGRect = .zero }

/// The window a view is in, kept without re-rendering.
final class WindowBox {
    weak var window: NSWindow?
    /// An event with no window (or one from this window) belongs to this view.
    func owns(_ event: NSEvent?) -> Bool { event?.window == nil || window == nil || event?.window === window }
}

/// Fills a `WindowBox` once the view is placed in a window.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView { Reader(box: box) }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Reader: NSView {
        let box: WindowBox
        init(box: WindowBox) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); box.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
final class IdentityCache { var values:[String:(name:String,avatar:String?,id:String)] = [:] }

/// Grouped card used by the details panel.
struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 2)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MessageRow: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.transcriptColumnWidth) private var columnWidth
    let message: MessageSnapshot
    let showSender: Bool
    var showAvatar = false
    var reserveAvatar = false
    var highlighted = false
    var showThumbnails = true
    var senderName = ""
    var senderAvatar: String? = nil
    var senderID = ""
    var firstInRun = true
    var lastInRun = true
    var isGroup = false
    /// Every photo of a batch sent together; drawn as one grid in place of the single photo.
    var album: [MessageSnapshot] = []
    var onQuoteJump: (String) -> Void
    /// Finds the member an @tag names. A closure, not the store: observing the store made every
    /// SwiftUI row redraw on each keystroke in the composer.
    var resolveMention: (String) -> FeatureRow? = { _ in nil }
    @State private var showingProfile = false
    /// The member opened by clicking an @tag in this message.
    @State private var mentioned: FeatureRow?
    static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.showSender == rhs.showSender && lhs.showAvatar == rhs.showAvatar &&
        lhs.reserveAvatar == rhs.reserveAvatar && lhs.highlighted == rhs.highlighted && lhs.showThumbnails == rhs.showThumbnails &&
        lhs.senderName == rhs.senderName && lhs.senderAvatar == rhs.senderAvatar && lhs.senderID == rhs.senderID &&
        lhs.firstInRun == rhs.firstInRun && lhs.lastInRun == rhs.lastInRun && lhs.album == rhs.album
    }
    private var bubbleWidth:CGFloat {min(480,max(100,(columnWidth-32)*0.78))}
    /// A file without caption or quote is shown as a card on its own, outside the bubble.
    private var fileOnly: Bool { MediaPresentation.fileURL(message) != nil && caption.isEmpty && (message.replyToText ?? "").isEmpty && message.imageURL == nil }
    private var displayName: String { senderName.isEmpty ? message.senderName : senderName }
    /// Stickers play at their own size, without a bubble, like on Zalo.
    private var stickerURL: URL? { message.messageType == "chat.sticker" ? safeWebURL(message.imageURL) : nil }
    private var primary: Color { message.isOutgoing ? OutgoingBubble.current.textColor : Color(nsColor: .labelColor) }
    private var secondary: Color { message.isOutgoing ? OutgoingBubble.current.textColor.opacity(0.78) : Color(nsColor: .secondaryLabelColor) }
    private var inset: Color { message.isOutgoing ? OutgoingBubble.current.textColor.opacity(0.18) : Color.accentColor.opacity(0.08) }
    /// Received bubbles are near-opaque so text stays readable over any wallpaper.
    private var incomingFill: Color { scheme == .dark ? Color(white: 0.17) : .white }
    /// Media-only messages sit directly on the transcript, without a bubble.
    private var bare: Bool { (MediaPresentation.isBareImage(message) || album.count > 1) && showThumbnails }
    private var caption: String {
        let value=MediaPresentation.caption(message)
        return !showThumbnails && message.imageURL != nil && value.isEmpty ? "[Hình ảnh]" : value
    }
    /// Stable per-sender colour for names inside group bubbles.
    private var nameColor: Color {
        let palette: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink]
        let key = senderID.isEmpty ? displayName : senderID
        return palette[Int(key.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31 &+ $1.value) % 10_007 }) % palette.count]
    }
    /// Consecutive bubbles from one sender share a tight inner edge, as in Telegram and Messages.
    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 18, small: CGFloat = 6
        let topInner = firstInRun ? big : small, bottomInner = lastInRun ? small : small
        return message.isOutgoing
            ? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: lastInRun ? 4 : bottomInner, topTrailingRadius: topInner, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: topInner, bottomLeadingRadius: lastInRun ? 4 : bottomInner, bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
    /// Time only, slightly smaller and quieter than secondary text; no sent tick.
    private var timeLabel: some View {
        Text(message.date, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().opacity(0.82)
    }
    /// A message that is only a link becomes a card of its own, not a text bubble.
    private var linkOnly: Bool {
        guard MediaPresentation.showsLinkPreview(message), let link = message.linkURL else { return false }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == link || text == message.linkTitle || text == message.linkDescription
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 60) }
            else if reserveAvatar {
                if showAvatar {
                    Button { showingProfile = true } label: { AvatarView(name: displayName, url: senderAvatar, size: 32) }
                        .buttonStyle(.plain).help("Thông tin \(displayName)")
                        .windowBoundedPopover(isPresented: $showingProfile) {
                            ContactProfilePopover(userID: senderID, name: displayName, avatar: senderAvatar) { showingProfile = false }
                        }
                } else { Color.clear.frame(width: 32, height: 1) }
            }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if let stickerURL {
                    if showSender { senderLine.padding(.leading, 4) }
                    TranscriptSticker(message: message, fallback: stickerURL)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 17).strokeBorder(Color.orange, lineWidth: 2) } }
                        .overlay(alignment: .bottomTrailing) { timeLabel.foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 2).background(.black.opacity(0.35), in: Capsule()) }
                } else if let contact = ContactCardInfo(message) {
                    if showSender { senderLine.padding(.leading, 4) }
                    ContactShareCard(info: contact, time: message.date)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if let record = CallRecord(message) {
                    CallCard(record: record, outgoing: message.isOutgoing, time: message.date)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if let voice = RichMedia.voiceURL(message) {
                    if showSender { senderLine.padding(.leading, 4) }
                    VoiceCard(url: voice, outgoing: message.isOutgoing, time: message.date)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if let video = RichMedia.video(message) {
                    if showSender { senderLine.padding(.leading, 4) }
                    VideoCard(url: video.url, thumbnail: video.thumbnail, time: message.date)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if let link = linkOnly ? safeWebURL(message.linkURL) : RichMedia.plainURL(message) {
                    if showSender { senderLine.padding(.leading, 4) }
                    RichLinkCard(url: link, title: message.linkTitle, thumbnail: safeWebURL(message.linkThumbnail), time: message.date,
                                 summary: message.linkDescription)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if let point = LocationPoint(message) {
                    if showSender { senderLine.padding(.leading, 4) }
                    LocationCard(point: point, senderName: message.isOutgoing ? "Tôi" : displayName, senderAvatar: senderAvatar)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else if fileOnly, let fileURL = safeWebURL(MediaPresentation.fileURL(message)) {
                    if showSender { senderLine.padding(.leading, 4) }
                    FileCard(message: message, remote: fileURL)
                        .overlay { if highlighted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 2) } }
                } else {
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                    if showSender && !bare { senderLine }
                    if let reply = message.replyToText, !reply.isEmpty {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(message.isOutgoing ? OutgoingBubble.current.textColor : Color.accentColor).frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = message.replyToSender { Text(verbatim: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(message.isOutgoing ? OutgoingBubble.current.textColor : Color.accentColor) }
                                Text(verbatim: reply).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5).padding(.horizontal, 6)
                        .background(inset, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                        .onTapGesture { if let original = message.replyToID { onQuoteJump(original) } }
                        .help("Đến tin được trả lời")
                    }
                    if showThumbnails, album.count > 1 {
                        PhotoAlbumGrid(photos: album, width: min(420, bubbleWidth))
                            .overlay(alignment: .bottomTrailing) {
                                timeLabel.foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,3).background(.black.opacity(0.4),in:Capsule()).padding(7)
                                    .allowsHitTesting(false)
                            }
                    } else if showThumbnails, let url = MediaSource.photo(message) {
                        Button { NotificationCenter.default.post(name: .openImageViewer, object: url) } label: {
                            // The photo sizes itself; a wider frame here centred it away from the bubble edge.
                            DownsampledPhoto(url:url,outgoing:message.isOutgoing)
                            .clipShape(RoundedRectangle(cornerRadius: bare ? 16 : 10))
                            .overlay(alignment: .bottomTrailing) {
                                if bare { timeLabel.foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,3).background(.black.opacity(0.4),in:Capsule()).padding(7) }
                            }
                        }
                        .buttonStyle(.plain).help("Xem ảnh")
                    }
                    if let fileURL = safeWebURL(MediaPresentation.fileURL(message)) {
                        FileCard(message: message, remote: fileURL).padding(.vertical, -2)
                    }
                    if MediaPresentation.showsLinkPreview(message), let link = safeWebURL(message.linkURL) {
                        LinkCard(url: link, title: message.linkTitle, thumbnail: safeWebURL(message.linkThumbnail), time: nil)
                            .padding(.horizontal, -5).padding(.top, -1)
                    }
                    if !caption.isEmpty {
                        HStack(alignment:.lastTextBaseline,spacing:7) {
                            Text(MessageTypography.withMentions(caption, outgoing: message.isOutgoing))
                                .font(.system(size:MessageTextSize.size(14))).foregroundStyle(primary).textSelection(.enabled)
                                .tint(message.isOutgoing ? primary : .accentColor)
                                .lineSpacing(1.5).fixedSize(horizontal:false,vertical:true)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard url.scheme == MessageTypography.mentionScheme else { return .systemAction }
                                    mentioned = resolveMention(url.path)
                                    return .handled
                                })
                                .windowBoundedPopover(isPresented: Binding(get: { mentioned != nil }, set: { if !$0 { mentioned = nil } })) {
                                    if let member = mentioned {
                                        ContactProfilePopover(userID: member.id, name: member.string("name", "display_name"),
                                                              avatar: member.string("avatar").isEmpty ? nil : member.string("avatar")) { mentioned = nil }
                                    }
                                }
                            timeLabel.foregroundStyle(secondary).fixedSize()
                        }
                    }
                    if message.text.isEmpty && message.imageURL == nil && message.fileURL == nil && MediaPresentation.fileURL(message) == nil {
                        Label("Loại tin này chưa hiển thị được — xem trên điện thoại", systemImage: "bubble.left").font(.callout).foregroundStyle(secondary)
                    }
                }
                .padding(.horizontal, bare ? 0 : 11).padding(.top, bare ? 0 : 6).padding(.bottom, bare ? 0 : 7)
                .overlay(alignment: .bottomTrailing) { if !bare && caption.isEmpty { timeLabel.foregroundStyle(secondary).padding(.trailing, 9).padding(.bottom, 5) } }
                .background { if !bare { shape.fill(message.isOutgoing ? OutgoingBubble.current.fillStyle : AnyShapeStyle(incomingFill)) } }
                .shadow(color: .black.opacity(bare ? 0 : 0.06), radius: 1, y: 1)
                .overlay { if highlighted { shape.strokeBorder(Color.orange, lineWidth: 2) } }
                .frame(maxWidth: bubbleWidth, alignment: message.isOutgoing ? .trailing : .leading)
                }
                if ReactionChips.hasReactions(message) {
                    ReactionChips(message: message, fill: incomingFill).padding(.horizontal, 6).padding(.top, -8)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.bottom, lastInRun ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .animation(reducedMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7), value: ReactionChips.details(message))
    }

    private var senderLine: some View {
        Text(verbatim: displayName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(nameColor).lineLimit(1)
            .onTapGesture { if isGroup { showingProfile = true } }
    }
}
