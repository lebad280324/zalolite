import AppKit
import SwiftUI
import NativeBridge

/// Development-only counters read by the frame probe; never consulted by layout.
enum TranscriptDiagnostics {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var configured = 0
    nonisolated(unsafe) static var measured = 0
    nonisolated(unsafe) static var drawn = 0
    nonisolated(unsafe) static var drawNanos: UInt64 = 0
    nonisolated(unsafe) static var layouts = 0
    nonisolated(unsafe) static var layoutNanos: UInt64 = 0
    nonisolated(unsafe) static var appearanceRedraws = 0
    nonisolated(unsafe) static var applyRedraws = 0
    nonisolated(unsafe) static var updateMaxNanos: UInt64 = 0
    nonisolated(unsafe) static var contentUpdateMaxNanos: UInt64 = 0
    static func reset() { configured = 0; measured = 0; drawn = 0; drawNanos = 0; layouts = 0; layoutNanos = 0; appearanceRedraws = 0; applyRedraws = 0; updateMaxNanos = 0; contentUpdateMaxNanos = 0 }
}

struct TranscriptAnchor {
    let messageID: String
    let offset: CGFloat
    let bottom: Bool
}

private struct TranscriptColumnWidthKey: EnvironmentKey {static let defaultValue:CGFloat=640}
private struct TranscriptMediaActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var transcriptColumnWidth:CGFloat {get{self[TranscriptColumnWidthKey.self]} set{self[TranscriptColumnWidthKey.self]=newValue}}
    var transcriptMediaActive: Bool {
        get {self[TranscriptMediaActiveKey.self]}
        set {self[TranscriptMediaActiveKey.self]=newValue}
    }
}

/// AppKit recycles the visible cells while the model retains each chat's reading position.
@MainActor struct NativeTranscript: NSViewRepresentable {
    let model: TranscriptModel
    let threadID: String
    let rows: [TranscriptRow]
    let jump: String?
    let configuration: Int
    var geometryConfiguration:Int=0
    /// Rows this returns an input for are drawn with CoreText; `nil` keeps the SwiftUI row.
    var native: ((TranscriptRow) -> NativeRowInput?)? = nil
    var nativeActions = NativeRowActions()
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 8
    let content: (TranscriptRow) -> AnyView
    let loadMore: () -> Void
    let loadNewer: () -> Void
    let bottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        Self.viewportSize(proposal, fallback: nsView.frame.size)
    }

    static func viewportSize(_ proposal: ProposedViewSize, fallback: CGSize) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(1, fallback.width)
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? max(1, fallback.height)
        return CGSize(width: max(0, width), height: max(0, height))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top:topInset,left:0,bottom:bottomInset,right:0)
        scroll.contentView.wantsLayer=true
        scroll.contentView.layer?.masksToBounds=true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.minWidth = 10
        column.maxWidth = 100_000
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector:#selector(Coordinator.resized),name:NSView.frameDidChangeNotification,object:scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector:#selector(Coordinator.endedLiveResize),name:NSWindow.didEndLiveResizeNotification,object:nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector:#selector(Coordinator.startedScrolling), name:NSScrollView.willStartLiveScrollNotification, object:scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector:#selector(Coordinator.endedScrolling), name:NSScrollView.didEndLiveScrollNotification, object:scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.savePosition()
        coordinator.cancelPreparation()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeTranscript
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        var displayed: [TranscriptRow] = []
        private var rowHeights: [CGFloat] = []
        var width: CGFloat = 0
        private var viewportWidth:CGFloat=0
        private var viewportHeight:CGFloat=0
        var restoring = false
        var initialized = false
        private let measuringCell=TranscriptCell()
        private var scrollScheduled=false
        private var preparationWork: DispatchWorkItem?
        private var layoutGeneration = 0
        private var pendingHeights = IndexSet()
        private var liveScrolling = false
        var lastJump: String?
        var isBottom = true
        private var layouts: [String: MessageRowLayout] = [:]
        private var lastResize: UInt64 = 0

        /// Geometry for a natively drawn row at the current width, or `nil` for a SwiftUI row.
        private func nativeLayout(_ row: TranscriptRow) -> MessageRowLayout? {
            guard let input = parent.native?(row) else { return nil }
            if let known = layouts[row.id], known.width == width, known.input.sameLayout(as: input),
               known.input.selected == input.selected, known.input.highlighted == input.highlighted,
               known.input.swipeOffset == input.swipeOffset, known.input.senderAvatar == input.senderAvatar { return known }
            if layouts.count > 900 { layouts.removeAll(keepingCapacity: true) }
            let started = TranscriptDiagnostics.enabled ? DispatchTime.now().uptimeNanoseconds : 0
            defer { if TranscriptDiagnostics.enabled { TranscriptDiagnostics.layouts += 1; TranscriptDiagnostics.layoutNanos += DispatchTime.now().uptimeNanoseconds-started } }
            let layout = MessageRowLayout(input, width: width)
            layouts[row.id] = layout
            return layout
        }

        func messageUnderPointer() -> String? {
            guard let table, let scroll, let window = table.window else { return nil }
            let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard scroll.contentView.bounds.contains(point) else { return nil }
            let row = table.row(at: point)
            return displayed.indices.contains(row) ? displayed[row].id : nil
        }

        /// The window showing this transcript, for routing pointer events between windows.
        var window: NSWindow? { table?.window }

        init(_ parent: NativeTranscript) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("transcript-row")
            let view = (tableView.makeView(withIdentifier: id, owner: nil) as? TranscriptRowView) ?? TranscriptRowView()
            view.identifier = id
            return view
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard displayed.indices.contains(row) else { return 70 }
            return rowHeights[row]
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayed.indices.contains(row) else { return nil }
            if let layout = nativeLayout(displayed[row]) {
                let id = NSUserInterfaceItemIdentifier("native-cell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeMessageCell)
                    ?? NativeMessageCell(frame: NSRect(x: 0, y: 0, width: width, height: layout.height))
                cell.identifier = id
                cell.apply(layout, actions: parent.nativeActions)
                if parent.model.height(for: displayed[row], width: width) == nil {
                    parent.model.rememberHeight(layout.height, for: displayed[row], width: width)
                    if rowHeights[row] != layout.height { rowHeights[row] = layout.height; pendingHeights.insert(row) }
                    scrolled()
                }
                return cell
            }
            let id = NSUserInterfaceItemIdentifier("message-cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? TranscriptCell) ?? TranscriptCell()
            cell.identifier = id
            let item = displayed[row]
            let knownHeight = parent.model.height(for:item,width:width)
            let height = cell.configure(parent.content(item), width: max(100, width), knownHeight: knownHeight)
            cell.representedRow = item
            cell.representedThreadID = parent.threadID
            cell.configuration = parent.configuration
            if knownHeight == nil {
                parent.model.rememberHeight(height,for:item,width:width)
                if rowHeights[row] != height {rowHeights[row] = height;pendingHeights.insert(row)}
                scrolled()
            }
            cell.setMediaActive(tableView.rect(ofRow:row).intersects(scroll?.contentView.bounds ?? .zero))
            return cell
        }

        @discardableResult private func prepareHeight(at index:Int) -> CGFloat {
            let row = displayed[index]
            let height: CGFloat
            if let cached = parent.model.height(for:row,width:width) {height = cached}
            else if let layout = nativeLayout(row) {
                height = layout.height
                parent.model.rememberHeight(height,for:row,width:width)
            }
            else if let table,index < table.numberOfRows,
                    let cell = table.view(atColumn:0,row:index,makeIfNecessary:false) as? TranscriptCell,
                    represents(cell,row:row) {
                height = cell.reflow(width:width)
                parent.model.rememberHeight(height,for:row,width:width)
            }
            else {
                height = measuringCell.configure(parent.content(row),width:max(100,width))
                parent.model.rememberHeight(height,for:row,width:width)
            }
            if rowHeights[index] != height {rowHeights[index] = height;pendingHeights.insert(index)}
            return height
        }

        /// Offscreen estimates retain document geometry until their exact layout is needed.
        private func prepareViewport(around anchor:TranscriptAnchor?) {
            guard !displayed.isEmpty else{return}
            let bottom = anchor?.bottom ?? true
            let start = bottom ? displayed.count-1 : displayed.firstIndex(where:{$0.id == anchor?.messageID}) ?? 0
            var index = bottom ? start : max(0,start-1)
            var covered: CGFloat = 0
            let target = viewportHeight + (bottom ? 80 : max(0,anchor?.offset ?? 0)+160)
            while displayed.indices.contains(index),covered < target {
                covered += prepareHeight(at:index)
                index += bottom ? -1 : 1
            }
        }

        private func applyPendingHeights(preserving anchor:TranscriptAnchor?) {
            guard let table,let scroll,!pendingHeights.isEmpty else{return}
            let pending = pendingHeights
            pendingHeights.removeAll()
            // A row that is not changing stays exactly where it is on screen; a corrected row
            // entering at the top therefore grows upwards instead of pushing what is being read.
            var reference:(index:Int,y:CGFloat)?
            if anchor?.bottom != true {
                let clip = scroll.contentView.bounds
                let visible = table.rows(in:clip)
                if visible.location != NSNotFound {
                    for index in visible.location..<min(displayed.count,visible.location+visible.length) where !pending.contains(index) {
                        reference = (index,table.rect(ofRow:index).minY-clip.minY);break
                    }
                }
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            defer {NSAnimationContext.endGrouping()}
            table.noteHeightOfRows(withIndexesChanged:pending)
            table.layoutSubtreeIfNeeded()
            guard let reference,reference.index < table.numberOfRows else {restore(anchor);return}
            let top = -scroll.contentInsets.top
            let bottom = max(top,table.bounds.height-scroll.contentView.bounds.height+scroll.contentInsets.bottom)
            let y = max(top,min(bottom,table.rect(ofRow:reference.index).minY-reference.y))
            if abs(y-scroll.contentView.bounds.minY) > 0.01 {
                scroll.contentView.scroll(to:NSPoint(x:0,y:y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// Exact heights for natively drawn rows around a range, nearest first, within a small time budget.
        /// Rows are then already correct before they scroll into view.
        private func prepareNativeRows(around lower:Int,_ upper:Int,reach:CGFloat,budget:UInt64) {
            let start = DispatchTime.now().uptimeNanoseconds
            var up = lower-1,down = upper+1,above:CGFloat = 0,below:CGFloat = 0
            func exact(_ index:Int) -> CGFloat {
                let row = displayed[index]
                if parent.model.height(for:row,width:width) != nil || parent.native?(row) != nil {return prepareHeight(at:index)}
                return rowHeights[index]
            }
            while (up >= 0 && above < reach) || (down < displayed.count && below < reach) {
                if up >= 0,above < reach {above += exact(up);up -= 1}
                if down < displayed.count,below < reach {below += exact(down);down += 1}
                if DispatchTime.now().uptimeNanoseconds-start >= budget {break}
            }
        }

        private func prepareVisibleRows(preserving anchor:TranscriptAnchor?) {
            guard let table,let scroll else{return}
            // A correction can expose another row at the viewport edge.
            for _ in 0..<3 {
                let visible = table.rows(in:scroll.contentView.bounds)
                guard visible.location != NSNotFound else{break}
                for index in max(0,visible.location-1)..<min(displayed.count,visible.location+visible.length+1) {
                    prepareHeight(at:index)
                }
                guard !pendingHeights.isEmpty else{break}
                applyPendingHeights(preserving:anchor)
            }
        }

        private func configureAvailableCells() {
            guard let table else{return}
            var replaced = IndexSet()
            defer {if !replaced.isEmpty {table.reloadData(forRowIndexes:replaced,columnIndexes:IndexSet(integer:0))}}
            table.enumerateAvailableRowViews {view,index in
                guard self.displayed.indices.contains(index) else{return}
                let row = self.displayed[index]
                if let cell = view.view(atColumn:0) as? NativeMessageCell {
                    if let layout = self.nativeLayout(row) {cell.apply(layout,actions:self.parent.nativeActions)} else {replaced.insert(index)}
                    return
                }
                guard let cell = view.view(atColumn:0) as? TranscriptCell else{return}
                if self.parent.native?(row) != nil {replaced.insert(index);return}
                if self.represents(cell,row:row) {
                    if cell.contentWidth != self.width {_ = cell.reflow(width:self.width,knownHeight:self.rowHeights[index])}
                } else {
                    _ = cell.configure(self.parent.content(row),width:self.width,knownHeight:self.rowHeights[index])
                    cell.representedRow = row
                    cell.representedThreadID = self.parent.threadID
                    cell.configuration = self.parent.configuration
                }
            }
        }

        private func represents(_ cell:TranscriptCell,row:TranscriptRow) -> Bool {
            cell.representedThreadID == parent.threadID && cell.configuration == parent.configuration &&
                cell.representedRow.map{Self.same($0,row)} == true
        }

        func cancelPreparation() {
            layoutGeneration += 1
            preparationWork?.cancel()
            preparationWork = nil
        }

        private func schedulePreparation(after delay:TimeInterval = 0.016) {
            guard preparationWork == nil,!liveScrolling,scroll?.window != nil,
                  displayed.contains(where:{parent.model.height(for:$0,width:width) == nil}) else{return}
            let generation = layoutGeneration
            let work = DispatchWorkItem {[weak self] in
                guard let self,self.layoutGeneration == generation else{return}
                self.preparationWork = nil
                self.prepareNextBatch()
            }
            preparationWork = work
            DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
        }

        private func prepareNextBatch() {
            guard let scroll,let table else{return}
            guard !restoring,!scroll.inLiveResize,!table.inLiveResize,scroll.window?.inLiveResize != true else {
                schedulePreparation(after:0.1);return
            }
            let saved = anchor()
            restoring = true
            defer {restoring = false}
            let start = DispatchTime.now().uptimeNanoseconds
            var count = 0
            for index in displayed.indices where parent.model.height(for:displayed[index],width:width) == nil {
                prepareHeight(at:index)
                count += 1
                // Layout is main-actor work; yield between short slices instead of blocking a whole page.
                if count >= 120 || DispatchTime.now().uptimeNanoseconds-start >= 2_000_000 {break}
            }
            applyPendingHeights(preserving:saved)
            prepareVisibleRows(preserving:saved)
            savePosition()
            schedulePreparation()
        }

        func update(_ value: NativeTranscript) {
            guard TranscriptDiagnostics.enabled else {apply(value);return}
            let start = DispatchTime.now().uptimeNanoseconds
            let rowsBefore = displayed.count
            apply(value)
            let spent = DispatchTime.now().uptimeNanoseconds-start
            TranscriptDiagnostics.updateMaxNanos = max(TranscriptDiagnostics.updateMaxNanos,spent)
            if rowsBefore != displayed.count {TranscriptDiagnostics.contentUpdateMaxNanos = max(TranscriptDiagnostics.contentUpdateMaxNanos,spent)}
        }

        private func apply(_ value: NativeTranscript) {
            guard let table, let scroll else { return }
            let newViewportWidth=floor(scroll.contentView.bounds.width)
            let newViewportHeight=scroll.contentView.bounds.height
            let heightChanged=newViewportHeight != viewportHeight
            let viewportChanged=newViewportWidth != viewportWidth || heightChanged
            let threadChanged = parent.threadID != value.threadID
            let saved = threadChanged || !initialized || viewportChanged ? value.model.positions[value.threadID] : anchor()
            let previous = displayed
            let reconfigure = parent.configuration != value.configuration
            let geometryChanged=parent.geometryConfiguration != value.geometryConfiguration
            let insetsChanged = scroll.contentInsets.top != value.topInset || scroll.contentInsets.bottom != value.bottomInset
            parent = value
            // Insets reserve readable endpoints while the viewport continues behind the floating controls.
            if insetsChanged {
                scroll.contentInsets = NSEdgeInsets(top:value.topInset,left:0,bottom:value.bottomInset,right:0)
            }
            guard newViewportWidth>=100,newViewportHeight>0 else{return}
            let oldRestoring=restoring;restoring=true
            defer {restoring=oldRestoring}
            TranscriptPointer.active = self
            if newViewportWidth != viewportWidth || !initialized {
                table.setFrameSize(NSSize(width:newViewportWidth,height:table.frame.height))
                table.sizeLastColumnToFit()
            }
            // Content is laid out for the viewport, never for a column that has not been sized yet.
            let newWidth=newViewportWidth
            let resized=newViewportWidth != viewportWidth || newWidth != width
            viewportWidth=newViewportWidth
            viewportHeight=newViewportHeight
            if geometryChanged {value.model.invalidateHeights()}
            if geometryChanged || threadChanged || newWidth != width {layouts.removeAll(keepingCapacity:true)}
            if newWidth != width {lastResize = DispatchTime.now().uptimeNanoseconds}
            width=newWidth
            let changed = previous.count != value.rows.count || zip(previous, value.rows).contains { !Self.same($0, $1) }
            if changed || resized || heightChanged || insetsChanged || reconfigure || geometryChanged || threadChanged || !initialized {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration=0
                NSAnimationContext.current.allowsImplicitAnimation=false
                defer {NSAnimationContext.endGrouping()}
                restoring = true
                if changed || resized || geometryChanged || threadChanged {cancelPreparation()}
                value.model.beginHeightBatch(value.rows.count)
                let oldHeights = Dictionary(uniqueKeysWithValues:zip(previous,rowHeights).map{($0.0.id,$0.1)})
                displayed = value.rows
                rowHeights = displayed.map {value.model.height(for:$0,width:width) ?? value.model.estimatedHeight(for:$0) ?? oldHeights[$0.id] ?? 80}
                pendingHeights.removeAll()
                prepareViewport(around:saved)
                if changed || threadChanged || !initialized {
                    let pivot = saved?.bottom != false ? displayed.count-1 : displayed.firstIndex(where:{$0.id == saved?.messageID}) ?? displayed.count-1
                    prepareNativeRows(around:pivot,pivot,reach:viewportHeight*3,budget:2_500_000)
                }
                let oldIDs = previous.map(\.id), newIDs = displayed.map(\.id)
                let oldSet = Set(oldIDs), newSet = Set(newIDs)
                let sharedOld = oldIDs.filter { newSet.contains($0) }
                let sharedNew = newIDs.filter { oldSet.contains($0) }
                if initialized, !threadChanged, sharedOld == sharedNew {
                    let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
                    let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
                    if !removed.isEmpty || !inserted.isEmpty {
                        table.beginUpdates()
                        table.removeRows(at:removed,withAnimation:[])
                        table.insertRows(at:inserted,withAnimation:[])
                        table.endUpdates()
                    }
                    let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                    let changedRows=IndexSet(displayed.indices.filter {i in old[displayed[i].id].map{!Self.same($0,displayed[i])} ?? false})
                    pendingHeights.formUnion(changedRows)
                    if resized || geometryChanged {pendingHeights.formUnion(IndexSet(integersIn:displayed.indices))}
                    if !pendingHeights.isEmpty {table.noteHeightOfRows(withIndexesChanged:pendingHeights);pendingHeights.removeAll()}
                    if !changedRows.isEmpty {table.reloadData(forRowIndexes:changedRows,columnIndexes:IndexSet(integer:0))}
                    if resized || reconfigure || changed {configureAvailableCells()}
                } else { table.reloadData() }
                if changed || resized || heightChanged || insetsChanged || geometryChanged || !initialized {
                    table.layoutSubtreeIfNeeded()
                    restore(saved)
                    prepareVisibleRows(preserving:saved)
                }
                initialized = true
                savePosition()
                schedulePreparation(after:resized ? 0.12 : 0.016)
            }
            if let jump = value.jump, jump != lastJump, let index = displayed.firstIndex(where: { $0.id == jump }) {
                prepareViewport(around:TranscriptAnchor(messageID:jump,offset:0,bottom:false))
                applyPendingHeights(preserving:anchor())
                let top = -scroll.contentInsets.top
                let bottom = max(top,table.bounds.height-scroll.contentView.bounds.height+scroll.contentInsets.bottom)
                scroll.contentView.scroll(to:NSPoint(x:0,y:max(top,min(bottom,table.rect(ofRow:index).minY-scroll.contentInsets.top))))
                scroll.reflectScrolledClipView(scroll.contentView)
                prepareVisibleRows(preserving:anchor())
                lastJump = jump
            }
            if value.jump == nil { lastJump = nil }
            updateVisibleMedia()
        }

        static func same(_ a: TranscriptRow, _ b: TranscriptRow) -> Bool {
            a.message == b.message && a.showsTimestamp == b.showsTimestamp && a.startsRun == b.startsRun && a.endsRun == b.endsRun && a.album == b.album
        }

        func anchor() -> TranscriptAnchor? {
            guard let table, let scroll, !displayed.isEmpty else { return nil }
            let visible = scroll.contentView.bounds
            let atBottom = visible.maxY >= table.bounds.height + scroll.contentInsets.bottom - 24
            let range = table.rows(in: visible)
            guard range.location != NSNotFound, displayed.indices.contains(range.location) else { return nil }
            return TranscriptAnchor(messageID: displayed[range.location].id, offset: visible.minY - table.rect(ofRow: range.location).minY, bottom: atBottom)
        }

        func restore(_ anchor: TranscriptAnchor?) {
            guard let table, let scroll, !displayed.isEmpty else { return }
            let top = -scroll.contentInsets.top
            let bottom = max(top,table.bounds.height-scroll.contentView.bounds.height+scroll.contentInsets.bottom)
            let y: CGFloat
            if anchor == nil || anchor?.bottom == true {y=bottom}
            else if let anchor,let row=displayed.firstIndex(where:{$0.id==anchor.messageID}) {
                let offset=max(row==0 ? top : 0,min(anchor.offset,max(0,table.rect(ofRow:row).height-1)))
                y=table.rect(ofRow:row).minY+offset
            } else {return}
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(top,min(bottom,y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Development-only: rows on screen whose table height or content width differs from a fresh measurement.
        func diagnosticsVisibleMismatches() -> [String] {
            guard let table,let scroll else{return []}
            let visible = table.rows(in:scroll.contentView.bounds)
            guard visible.location != NSNotFound else{return []}
            var result:[String] = []
            for index in visible.location..<min(displayed.count,visible.location+visible.length) {
                let shown = table.rect(ofRow:index).height
                if let layout = nativeLayout(displayed[index]) {
                    let cell = table.view(atColumn:0,row:index,makeIfNecessary:false) as? NativeMessageCell
                    if abs(shown-layout.height) > 0.5 || cell?.content.layout?.width != width || abs((cell?.frame.height ?? 0)-shown) > 0.5 || cell?.content.frame.size != layout.ink.size {
                        result.append("\(displayed[index].id): row=\(shown) ideal=\(layout.height) drawnWidth=\(cell?.content.layout?.width ?? -1) width=\(width) content=\(cell?.content.frame.size ?? .zero)")
                    }
                    continue
                }
                let ideal = measuringCell.configure(parent.content(displayed[index]),width:max(100,width))
                let cell = table.view(atColumn:0,row:index,makeIfNecessary:false) as? TranscriptCell
                if abs(shown-ideal) > 0.5 || cell == nil || cell?.contentWidth != width || abs((cell?.frame.height ?? 0)-shown) > 0.5 {
                    result.append("\(displayed[index].id): row=\(shown) ideal=\(ideal) cellWidth=\(cell?.contentWidth ?? -1) width=\(width) cellHeight=\(cell?.frame.height ?? -1)")
                }
            }
            return result
        }

        func savePosition() { if let anchor = anchor() { if parent.model.threadID == parent.threadID {parent.model.positions[parent.threadID] = anchor} } }

        func updateVisibleMedia() {
            guard let table,let scroll else{return}
            let visible=scroll.contentView.bounds
            table.enumerateAvailableRowViews {view,row in
                (view.view(atColumn:0) as? TranscriptCell)?.setMediaActive(table.rect(ofRow:row).intersects(visible))
            }
        }

        @objc func scrolled() {
            guard !restoring,!scrollScheduled else{return}
            scrollScheduled=true
            DispatchQueue.main.async {[weak self] in
                guard let self else{return};self.scrollScheduled=false;self.flushScroll()
            }
        }

        /// A new viewport size is applied in the same layout pass, so rows never show one frame at the old width.
        @objc func resized() {
            guard !restoring,initialized else {scrolled();return}
            flushScroll()
        }

        /// After a drag on the window edge, lay out and repaint every visible row once at the final width.
        @objc func endedLiveResize(_ note: Notification) {
            guard let table, let scroll, (note.object as? NSWindow) === scroll.window else { return }
            flushScroll()
            configureAvailableCells()
            table.enumerateAvailableRowViews { view, _ in (view.view(atColumn: 0) as? NativeMessageCell)?.repaint() }
            scroll.contentView.needsDisplay = true
        }

        @objc func startedScrolling() {
            liveScrolling = true
            cancelPreparation()
        }

        @objc func endedScrolling() {
            liveScrolling = false
            flushScroll()
            schedulePreparation(after:0.1)
        }

        func flushScroll() {
            guard !restoring,let table,let scroll else{return}
            if floor(scroll.contentView.bounds.width) != viewportWidth || scroll.contentView.bounds.height != viewportHeight {update(parent)}
            guard initialized,!displayed.isEmpty else{return}
            let saved = anchor()
            restoring = true
            prepareVisibleRows(preserving:saved)
            let shown = table.rows(in:scroll.contentView.bounds)
            // While the width is still changing, rows outside the viewport would only be laid out to be thrown away.
            if shown.location != NSNotFound,DispatchTime.now().uptimeNanoseconds-lastResize > 250_000_000 {
                prepareNativeRows(around:shown.location,shown.location+shown.length-1,reach:viewportHeight*2,budget:1_200_000)
                applyPendingHeights(preserving:saved)
            }
            restoring = false
            updateVisibleMedia();savePosition()
            schedulePreparation()
            let bottom=scroll.contentView.bounds.maxY >= table.bounds.height+scroll.contentInsets.bottom-24
            if isBottom != bottom {isBottom=bottom;parent.bottomChanged(bottom)}
            if scroll.contentView.bounds.minY<400 {parent.loadMore()}
            else if scroll.contentView.bounds.maxY>table.bounds.height-400 {parent.loadNewer()}
        }

    }
}

/// The viewport has no content-derived size. SwiftUI must never fit the table's hosting-view subtree.
final class TranscriptScrollView: NSScrollView {
    override var fittingSize: NSSize { .zero }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

final class TranscriptCell: NSTableCellView {
    private var controller: NSHostingController<AnyView>?
    private var contentRoot: AnyView?
    private var content: AnyView?
    private(set) var contentWidth: CGFloat = 0
    var representedRow: TranscriptRow?
    var representedThreadID: String?
    var configuration: Int?
    private var mediaActive=false

    func setMediaActive(_ active:Bool) {
        guard mediaActive != active else{return}
        mediaActive=active
        if let root=contentRoot {controller?.rootView=AnyView(root.environment(\.transcriptMediaActive,active))}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {setMediaActive(false)}
    }

    func configure(_ content: AnyView, width: CGFloat, knownHeight: CGFloat? = nil) -> CGFloat {
        self.content = content
        contentWidth = width
        let root = AnyView(VStack(spacing: 2) { content }.padding(.horizontal, 16).padding(.vertical, 1).frame(width: width, alignment: .topLeading).fixedSize(horizontal:false,vertical:true).environment(\.transcriptColumnWidth,width))
        contentRoot=root
        let presented=AnyView(root.environment(\.transcriptMediaActive,mediaActive))
        let host: NSHostingController<AnyView>
        if let controller { host=controller;host.rootView=presented }
        else {
            host=NSHostingController(rootView:presented)
            // The table owns geometry; content constraints must not feed back into its layout engine.
            host.sizingOptions=[]
            #if LEGACY_MACOS13
            if #available(macOS 13.3, *) { host.safeAreaRegions=[] }
            #else
            host.safeAreaRegions=[]
            #endif
            host.view.autoresizingMask=[]
            addSubview(host.view)
            controller=host
        }
        if TranscriptDiagnostics.enabled {TranscriptDiagnostics.configured += 1;if knownHeight == nil {TranscriptDiagnostics.measured += 1}}
        let height=knownHeight ?? max(24,ceil(host.sizeThatFits(in:CGSize(width:width,height:.greatestFiniteMagnitude)).height))
        host.view.frame=NSRect(x:0,y:0,width:width,height:height)
        needsLayout=true
        return height
    }

    func reflow(width:CGFloat,knownHeight:CGFloat? = nil) -> CGFloat {
        guard let content else{return knownHeight ?? 80}
        return configure(content,width:width,knownHeight:knownHeight)
    }

    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        layoutHost()
    }
    override func setFrameOrigin(_ newOrigin:NSPoint) {super.setFrameOrigin(newOrigin);layoutHost()}
    override func layout() {super.layout();layoutHost()}
    private func layoutHost() {
        // The table insets its column inside the row; content is laid out for the whole row.
        let full=NSRect(x:-frame.minX,y:0,width:superview?.bounds.width ?? bounds.width,height:bounds.height)
        if let view=controller?.view,view.frame != full {view.frame=full}
    }
}
