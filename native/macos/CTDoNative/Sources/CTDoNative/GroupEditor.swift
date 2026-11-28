import SwiftUI
import NativeBridge
struct GroupEditor: View {
 @EnvironmentObject var store:AppStore
 @Environment(\.dismiss) var dismiss
 var thread:ThreadSnapshot? = nil
 var preselected:String? = nil
 @State var name=""
 @State var selected:Set<String>=[]
 var body:some View {
  VStack(alignment:.leading,spacing:16){
   HStack{Text(thread == nil ? "Tạo nhóm mới":"Mời vào nhóm").font(.title2.bold());Spacer();Button("Đóng"){dismiss()}}
   if thread == nil {TextField("Tên nhóm",text:$name).textFieldStyle(.roundedBorder)}
   List(store.features.contacts){row in Toggle(row.string("name"),isOn:Binding(get:{selected.contains(row.id)},set:{if $0{selected.insert(row.id)}else{selected.remove(row.id)}}))}
   Text("\(selected.count) người được chọn").foregroundStyle(.secondary)
   Button(thread == nil ? "Tạo nhóm":"Gửi lời mời"){
    var params:[String:JSONValue]=["member_ids":.array(selected.sorted().map{.string($0)})]
    if let thread{params["thread_id"] = .string(thread.id);store.send("add_group_members",parameters:params)}
    else{params["name"] = .string(name);store.send("create_group",parameters:params)}
   }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || (thread == nil && name.trimmingCharacters(in:.whitespaces).isEmpty))
   if let error=store.error{Text(verbatim:error).foregroundStyle(.orange)}
  }.padding(26).frame(width:490,height:490).onAppear{store.loadContactLists();if let preselected{selected.insert(preselected)}}
 }
}
