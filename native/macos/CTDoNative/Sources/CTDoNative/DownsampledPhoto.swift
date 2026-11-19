import SwiftUI
import AppKit
import ImageIO
import NativeBridge

private final class ImageTransfer:NSObject,URLSessionDataDelegate,@unchecked Sendable {
 private var bytes=Data()
 private var owner:URLSession?
 private let completion:@Sendable(Result<Data,Error>)->Void
 private let limit=20*1024*1024
 init(_ completion:@escaping @Sendable(Result<Data,Error>)->Void){self.completion=completion}
 func start(_ url:URL){let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=15;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;let queue=OperationQueue();queue.maxConcurrentOperationCount=1;owner=URLSession(configuration:config,delegate:self,delegateQueue:queue);owner?.dataTask(with:url).resume()}
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
  let status=(response as? HTTPURLResponse)?.statusCode ?? 0
  completionHandler(status==200 && response.expectedContentLength<=Int64(limit) ? .allow : .cancel)
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){if bytes.count+data.count>limit{dataTask.cancel()}else{bytes.append(data)}}
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if let error{completion(.failure(error))}else{completion(.success(bytes))};owner=nil;session.finishTasksAndInvalidate()}
 static func fetch(_ url:URL)async throws->Data {try await withCheckedThrowingContinuation{continuation in let request=ImageTransfer{continuation.resume(with:$0)};request.start(url)}}
}

private actor PhotoSlots {
 static let shared=PhotoSlots()
 private var active=0
 private var waiting:[CheckedContinuation<Void,Never>]=[]
 func acquire()async{if active<4{active+=1;return};await withCheckedContinuation{waiting.append($0)}}
 func release(){if waiting.isEmpty{active-=1}else{waiting.removeFirst().resume()}}
}

@MainActor final class PhotoCache {
 static let shared=PhotoCache()
 let cache=NSCache<NSURL,NSImage>()
 var pending:[URL:Task<NSImage,Error>]=[:]
 var failures:[URL:Date]=[:]
 init(){cache.totalCostLimit=160*1024*1024;cache.countLimit=200}
 func cached(_ url:URL)->NSImage?{cache.object(forKey:url as NSURL)}
 func image(_ url:URL)async throws->NSImage{
  if let image=cache.object(forKey:url as NSURL){return image}
  if let last=failures[url],Date().timeIntervalSince(last)<15{throw URLError(.resourceUnavailable)}
  let task:Task<NSImage,Error>
  if let existing=pending[url]{task=existing}else{
   task=Task.detached(priority:.utility){
    // A photo just sent is not served until Zalo finishes processing it; retry briefly before giving up.
    // The download slot is held only while fetching, never while waiting to retry.
    var data=Data()
    var lastError:Error=URLError(.badServerResponse)
    if url.isFileURL {
     // A copy imported from a Zalo export: read it straight from disk (JPEG XL decodes natively).
     data=(try? Data(contentsOf:url,options:.mappedIfSafe)) ?? Data()
    }
    let delays: [Double] = url.isFileURL ? [] : [0.0, 1.5, 4, 10]
    for (attempt,delay) in delays.enumerated() {
     if attempt>0{try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}
     await PhotoSlots.shared.acquire()
     do {data=try await ImageTransfer.fetch(url)} catch {lastError=error;data=Data()}
     await PhotoSlots.shared.release()
     if !data.isEmpty{break}
    }
    if data.isEmpty{throw lastError}
    guard let source=CGImageSourceCreateWithData(data as CFData,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1440,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)else{throw URLError(.cannotDecodeContentData)}
    return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
   };pending[url]=task
  }
  do{let image=try await task.value;pending[url]=nil;cache.setObject(image,forKey:url as NSURL,cost:Int(image.size.width*image.size.height)*4);return image}
  catch{pending[url]=nil;failures[url]=Date();if failures.count>256{failures.removeAll()};throw error}
 }
}

/// Development-only: the frame probe supplies synthetic photos without touching the network.
@MainActor func seedPhotoCacheForDiagnostics(_ url:URL,_ image:NSImage){PhotoCache.shared.cache.setObject(image,forKey:url as NSURL,cost:Int(image.size.width*image.size.height)*4)}

struct DownsampledPhoto: View {
 @Environment(\.transcriptColumnWidth) private var columnWidth
 @Environment(\.transcriptMediaActive) private var mediaActive
 private var imageWidth:CGFloat {min(280,max(80,(columnWidth-32)*0.78-22))}
 let url:URL
 var outgoing = false
 private var photoSize: CGSize {
  guard let image else { return CGSize(width:imageWidth,height:imageWidth*0.75) }
  return MessageMediaGeometry.fitted(image.size,in:CGRect(x:0,y:0,width:imageWidth,height:imageWidth*0.75),outgoing:outgoing).size
 }
 @State private var image:NSImage?
 @State private var loadedURL:URL?
 @State private var failed=false
 var body:some View {
  Group{
   if let image{Image(nsImage:image).resizable().scaledToFit().frame(width:photoSize.width,height:photoSize.height)}
   else{ZStack{Color.primary.opacity(0.055);Image(systemName:failed ? "photo.badge.exclamationmark" : "photo").font(.title2).foregroundStyle(.secondary)}.frame(width:imageWidth,height:imageWidth*0.75)}
  }.task(id:url.absoluteString+String(mediaActive)){guard mediaActive else{return};if loadedURL==url && image != nil{return};image=nil;failed=false;do{let decoded=try await PhotoCache.shared.image(url);guard !Task.isCancelled else{return};image=decoded;loadedURL=url}catch{if !Task.isCancelled{failed=true}}}

 }
}

/// Photos sent together, drawn as one grid like Zalo: rows of two or three square tiles.
struct PhotoAlbumGrid: View {
 let photos: [MessageSnapshot]
 let width: CGFloat
 private let gap: CGFloat = 2

 /// Row lengths: threes, with any remainder spread so no row holds a single photo.
 static func rowSizes(_ count: Int) -> [Int] {
  switch count {
  case ..<1: return []
  case 1, 2, 3: return [count]
  case 4: return [2, 2]
  default:
   switch count % 3 {
   case 0: return Array(repeating: 3, count: count / 3)
   case 1: return Array(repeating: 3, count: (count - 4) / 3) + [2, 2]
   default: return [2] + Array(repeating: 3, count: (count - 2) / 3)
   }
  }
 }

 var body: some View {
  let sizes = Self.rowSizes(photos.count)
  let starts = sizes.indices.map { sizes.prefix($0).reduce(0, +) }
  VStack(spacing: gap) {
   ForEach(Array(sizes.enumerated()), id: \.offset) { row, size in
    let side = (width - gap * CGFloat(size - 1)) / CGFloat(size)
    HStack(spacing: gap) {
     ForEach(photos[starts[row]..<starts[row] + size], id: \.id) { photo in
      PhotoTile(message: photo).frame(width: side, height: side)
     }
    }
   }
  }
  .frame(width: width)
  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  .accessibilityElement(children: .contain)
  .accessibilityLabel("\(photos.count) ảnh")
 }
}

/// One square tile of an album; the photo fills it and opens in the viewer.
private struct PhotoTile: View {
 @Environment(\.transcriptMediaActive) private var mediaActive
 let message: MessageSnapshot
 @State private var image: NSImage?
 @State private var failed = false
 private var url: URL? { MediaSource.photo(message) }
 var body: some View {
  Button { if let url { NotificationCenter.default.post(name: .openImageViewer, object: url) } } label: {
   ZStack {
    Color.primary.opacity(0.055)
    if let image {
     Image(nsImage: image).resizable().scaledToFill()
    } else {
     Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").font(.title3).foregroundStyle(.secondary)
    }
   }
   .clipped()
   .contentShape(Rectangle())
  }
  .buttonStyle(.plain)
  .help("Xem ảnh")
  .task(id: (url?.absoluteString ?? "") + String(mediaActive)) {
   guard mediaActive, let url, image == nil else { return }
   do { let decoded = try await PhotoCache.shared.image(url); if !Task.isCancelled { image = decoded } }
   catch { if !Task.isCancelled { failed = true } }
  }
 }
}
