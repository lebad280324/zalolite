import SwiftUI
import NativeBridge

/// Transcript dependencies are independent of drafts, menus and account-wide updates.
@MainActor final class TranscriptModel: ObservableObject {
 @Published var presentationVersion=0
 @Published private(set) var rows:[TranscriptRow]=[]
 private(set) var threadID:String?
 private var source:[MessageSnapshot]=[]
 private var query=""
 private var media=false
 private var generation=0
 private var work:Task<Void,Never>?
 var positions: [String: TranscriptAnchor] = [:]
 private struct Height { let row: TranscriptRow; let width: CGFloat; let value: CGFloat }
 private var heights: [String: Height] = [:]
 func reset(){work?.cancel();source=[];rows=[];positions.removeAll();heights.removeAll()}
 func height(for row: TranscriptRow, width: CGFloat) -> CGFloat? {
  guard let cached=heights[row.id],cached.width==width,cached.row.message==row.message,cached.row.showsTimestamp==row.showsTimestamp,cached.row.startsRun==row.startsRun,cached.row.endsRun==row.endsRun else{return nil};return cached.value
 }
 func estimatedHeight(for row:TranscriptRow)->CGFloat? {
  guard let cached=heights[row.id],NativeTranscript.Coordinator.same(cached.row,row) else{return nil}
  return cached.value
 }
 func invalidateHeights(){heights.removeAll()}
 func beginHeightBatch(_ count:Int){if heights.count+count>5000{heights.removeAll()}}
 func rememberHeight(_ height: CGFloat, for row: TranscriptRow, width: CGFloat){
  heights[row.id]=Height(row:row,width:width,value:height)
 }
 var lastID:String?{source.last?.id}
 func activate(_ id:String?,messages:[MessageSnapshot]){threadID=id;query="";media=false;source=messages;rebuild()}
 func replace(_ messages:[MessageSnapshot]){source=messages;rebuild()}
 func configure(query:String,media:Bool,threadID:String?=nil){guard threadID == nil || self.threadID == threadID else{return};guard query != self.query || media != self.media else{return};self.query=query;self.media=media;rebuild()}
 private func rebuild(){
  generation += 1;let token=generation;work?.cancel()
  let source=source,query=query,media=media
  // Search no longer filters: every message stays and matches are highlighted in place.
  // Reassigning the rows redraws them with the new search text.
  _ = token; _ = query
  rows=TranscriptLayout.rows(source,mediaOnly:media)
 }
}

struct TranscriptPane<RowContent:View>: View,Equatable {
 @ObservedObject var model:TranscriptModel
 let threadID:String
 let hovered:String?
 let selection:Set<String>
 let selecting:Bool
 let highlighted:String?
 let showThumbnails:Bool
 let swipeID:String?
 let swipeOffset:CGFloat
 let jump:String?
 let loading:Bool
 let rowContent:(TranscriptRow,Bool)->RowContent
 var nativeRow:((TranscriptRow)->NativeRowInput?)?=nil
 var nativeActions=NativeRowActions()
 var topInset:CGFloat=0
 var bottomInset:CGFloat=8
 let loadMore:()->Void
 let loadNewer:()->Void
 @Environment(\.accessibilityReduceMotion) private var reduced
 @Environment(\.colorScheme) private var scheme
 @State private var atBottom=true
 static func ==(a:Self,b:Self)->Bool{a.model===b.model && a.threadID==b.threadID && a.hovered==b.hovered && a.selection==b.selection && a.selecting==b.selecting && a.highlighted==b.highlighted && a.showThumbnails==b.showThumbnails && a.swipeID==b.swipeID && a.swipeOffset==b.swipeOffset && a.jump==b.jump && a.loading==b.loading && a.topInset==b.topInset && a.bottomInset==b.bottomInset}
 private var configuration: Int {
  var hash=Hasher();hash.combine(scheme);hash.combine(model.presentationVersion);hash.combine(selection);hash.combine(selecting);hash.combine(highlighted);hash.combine(showThumbnails);hash.combine(swipeID);hash.combine(swipeOffset);return hash.finalize()
 }
 private var geometryConfiguration:Int {
  var hash=Hasher();hash.combine(model.presentationVersion);hash.combine(selecting);hash.combine(showThumbnails);return hash.finalize()
 }
 var body:some View {
  NativeTranscript(model:model,threadID:threadID,rows:model.rows,jump:jump,configuration:configuration,geometryConfiguration:geometryConfiguration,native:nativeRow,nativeActions:nativeActions,topInset:topInset,bottomInset:bottomInset,
   content:{AnyView(rowContent($0,hovered == $0.id))},loadMore:loadMore,loadNewer:loadNewer,bottomChanged:{atBottom=$0})
   .frame(maxWidth:.infinity,maxHeight:.infinity)
   .overlay(alignment:.bottomTrailing){
    if !atBottom && !model.rows.isEmpty {
     Button { NotificationCenter.default.post(name:.transcriptLatest,object:threadID) } label:{
      Image(systemName:"chevron.down").font(.system(size:16,weight:.semibold)).frame(width:42,height:42).contentShape(Circle())
     }.buttonStyle(.plain).nativeGlass(21).help("Đến tin mới nhất").padding(18).padding(.bottom,bottomInset)
    }
   }
   .overlay(alignment:.top){if loading && !model.rows.isEmpty {ProgressView().controlSize(.small).padding(.top,topInset+12).allowsHitTesting(false)}}
   .overlay{if model.rows.isEmpty {if loading{ProgressView("Đang tải tin nhắn…")}else{EmptyState("Chưa có nội dung",systemImage:"bubble.left",description:Text("Gửi lời chào hoặc tải lịch sử."))}}}
 }
}

extension Notification.Name {static let transcriptLatest=Notification.Name("ctdo.transcript.latest")}
