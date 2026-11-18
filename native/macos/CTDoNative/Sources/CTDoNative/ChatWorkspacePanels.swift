import SwiftUI
import AppKit
import NativeBridge

/// Invisible resize target keeps the two surfaces separate without a drawn divider.
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?
    var body: some View {
        Color.clear.frame(width:4).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture().onChanged { value in
                if start == nil { start = width }; width = min(380,max(250,(start ?? width)+value.translation.width))
            }.onEnded { _ in start = nil })
    }
}

struct GlobalSearchPanel: View {
    @EnvironmentObject private var store: AppStore
    let close: () -> Void
    @State private var query = ""
    @State private var kind = "contacts"
    @FocusState private var focused: Bool
    private var contacts: [FeatureRow] {
        let hidden=Set(store.threads.filter{$0.hidden && !store.hiddenUnlocked}.map(\.id))
        var rows = store.features.contacts.filter{!hidden.contains($0.id)}
        let ids = Set(rows.map(\.id))
        rows += store.threads.filter{(!$0.hidden || store.hiddenUnlocked) && !ids.contains($0.id)}.map{FeatureRow(value:.object(["id":.string($0.id),"name":.string($0.name),"avatar":.string($0.avatar ?? "")]))}
        return Array(rows.filter{query.isEmpty || $0.string("name","display_name").localizedStandardContains(query)}.prefix(100))
    }
    var body: some View {
        VStack(spacing:12) {
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm liên hệ, tin nhắn, tệp",text:$query).textFieldStyle(.plain).focused($focused)
                if !query.isEmpty {Button{query=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain)}
            }.padding(11).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:13))
            Picker("Tìm kiếm",selection:$kind){Text("Liên hệ").tag("contacts");Text("Tin nhắn").tag("messages");Text("Tệp").tag("files")}.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(spacing:5) {
                    if kind == "contacts" {
                        ForEach(contacts){row in
                            Button {
                                if store.threads.contains(where:{$0.id==row.id}){store.selectThread(row.id)}else{store.send("open_contact",parameters:["user_id":.string(row.id),"name":.string(row.string("name","display_name")),"avatar":.string(row.string("avatar"))])}
                                close()
                            } label: {HStack(spacing:10){AvatarView(name:row.string("name","display_name"),url:row.string("avatar"),size:36);Text(verbatim:row.string("name","display_name")).lineLimit(1);Spacer()}.padding(8).contentShape(Rectangle())}.buttonStyle(.plain)
                        }
                    } else {
                        if store.busy.contains("search_history"){ProgressView().padding()}
                        ForEach(store.historyResults){hit in
                            Button {store.jump(toThread:hit.threadID,messageID:hit.message.id);close()}label:{
                                HStack(alignment:.top,spacing:10){Image(systemName:kind == "files" ? "doc.text":"bubble.left").foregroundStyle(.tint).frame(width:26)
                                    VStack(alignment:.leading,spacing:4){Text(verbatim:store.threads.first{$0.id==hit.threadID}?.name ?? "Hội thoại đã lưu").font(.caption).foregroundStyle(.secondary);Text(verbatim:kind == "files" ? hit.message.fileName ?? hit.message.text:hit.message.text).lineLimit(3);Text(hit.message.date,format:.dateTime.day().month().year()).font(.caption2).foregroundStyle(.tertiary)};Spacer()}.padding(9).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if query.isEmpty {EmptyState("Nhập từ khóa",systemImage:"magnifyingglass",description:Text("Tìm trong lịch sử đã lưu trên máy."))}
                        else if store.historyResults.isEmpty && !store.busy.contains("search_history"){EmptyState("Không có kết quả",systemImage:"magnifyingglass")}
                    }
                }
            }
            if kind != "contacts" {Text("Lịch sử trên máy · tối đa 300 kết quả").font(.caption2).foregroundStyle(.secondary)}
        }.padding(16).frame(width:410,height:470).onAppear{focused=true;if store.supports("list_contacts"){store.send("list_contacts")}}
         .task(id:query+"/"+kind){guard kind != "contacts" else{return};store.historyResults=[];try? await Task.sleep(nanoseconds:220_000_000);guard !Task.isCancelled else{return};store.searchHistory(query,onlyCurrentThread:false,filesOnly:kind == "files")}
    }
}

struct ComposerActionPanel: View {
    @EnvironmentObject private var store: AppStore
    let thread:ThreadSnapshot
    let close:()->Void
    let card:()->Void
    let format:()->Void
    let schedule:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:3){
            Text("Thêm vào cuộc trò chuyện").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.vertical,7)
            action("Ảnh hoặc tệp","paperclip","Chọn tệp hoặc kéo vào khung chat"){store.chooseAttachment()}
            if store.supports("send_contact"){action("Gửi danh thiếp","person.crop.rectangle","Chia sẻ liên hệ Zalo",run:card)}
            action("Định dạng chữ","textformat","Đậm, nghiêng, gạch chân và danh sách",run:format)
            if store.supports("send_sticker"){action("Nhãn dán","face.smiling","Bộ sưu tập nhãn dán"){store.openStickers()}}
            Divider().padding(.vertical,5)
            action("Tạo nhắc hẹn","bell.badge","Thông báo nhắc trên máy này"){store.reminderThread=thread}
            action("Đánh dấu tin quan trọng","star","Chọn tin nhắn để lưu trên máy"){store.selectingMessages=true}
            action("Tin nhắn nhanh","text.bubble","Các câu trả lời thường dùng"){store.showingQuickReplies=true}
            if store.supports("schedule_message"){action("Hẹn giờ gửi","clock","Gửi nội dung đang soạn sau",run:schedule)}
            if store.supports("list_scheduled"){action("Tin nhắn đã hẹn","calendar","Xem và hủy lịch gửi"){store.showingScheduled=true;store.send("list_scheduled")}}
        }.padding(10).frame(width:300)
    }
    private func action(_ title:String,_ icon:String,_ detail:String,run:@escaping()->Void)->some View {
        Button{close();Task { @MainActor in try? await Task.sleep(nanoseconds:180_000_000);guard store.selectedThreadID==thread.id else{return};run() }}label:{HStack(spacing:11){Image(systemName:icon).font(.system(size:18)).foregroundStyle(.tint).frame(width:32,height:34).background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:9));VStack(alignment:.leading,spacing:2){Text(title).font(.system(size:13,weight:.medium));Text(detail).font(.system(size:10)).foregroundStyle(.secondary)};Spacer()}.padding(7).contentShape(RoundedRectangle(cornerRadius:11))}.buttonStyle(LivelyButtonStyle())
    }
}

struct FormattingPanel:View {
    var body:some View {
        VStack(alignment:.leading,spacing:12){Text("Định dạng nội dung").font(.headline)
            Text("Chọn chữ trong ô soạn rồi chọn kiểu. Định dạng sẽ được gửi bằng định dạng chữ của Zalo.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing:8){style("Đậm","bold","**");style("Nghiêng","italic","*");style("Gạch chân","underline","__");style("Gạch ngang","strikethrough","~~")}
            HStack{prefix("Tiêu đề","## ");prefix("Danh sách","- ");prefix("Đánh số","1. ")}
        }.padding(18).frame(width:340)
    }
    private func style(_ title:String,_ icon:String,_ marker:String)->some View{Button{NotificationCenter.default.post(name:.composerFormatSelection,object:marker)}label:{Image(systemName:icon).frame(width:42,height:34)}.help(title).buttonStyle(.bordered)}
    private func prefix(_ title:String,_ marker:String)->some View{Button(title){NotificationCenter.default.post(name:.composerFormatSelection,object:marker,userInfo:["prefix":true])}.buttonStyle(.bordered)}
}

struct ContactCardPicker:View {
    @EnvironmentObject private var store:AppStore
    @Environment(\.dismiss) private var dismiss
    let thread:ThreadSnapshot
    @State private var query=""
    @State private var selected:String?
    var body:some View {
        VStack(spacing:16){HStack{Text("Gửi danh thiếp").font(.title2.bold());Spacer();Button("Đóng"){dismiss()}.keyboardShortcut(.cancelAction)}
            Text("Gửi tới \(thread.name)").foregroundStyle(.secondary)
            TextField("Tìm liên hệ",text:$query).textFieldStyle(.roundedBorder)
            List(store.features.contacts.filter{query.isEmpty || $0.string("name","display_name").localizedStandardContains(query)},selection:$selected){row in HStack{AvatarView(name:row.string("name","display_name"),url:row.string("avatar"),size:34);Text(verbatim:row.string("name","display_name"))}.tag(row.id)}
            HStack{Spacer();Button("Gửi danh thiếp"){if let selected{store.send("send_contact",parameters:["thread_id":.string(thread.id),"contact_id":.string(selected)],threadID:thread.id);dismiss()}}.buttonStyle(.borderedProminent).disabled(selected==nil || !store.canSend)}
        }.padding(22).frame(width:420,height:460).onAppear{if store.supports("list_contacts"){store.send("list_contacts")}}
    }
}

extension Notification.Name {static let composerFormatSelection=Notification.Name("vn.ctdo.native.composerFormatSelection")}
